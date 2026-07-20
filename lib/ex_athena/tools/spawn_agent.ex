defmodule ExAthena.Tools.SpawnAgent do
  @moduledoc """
  Synchronously run a sub-agent-loop with its own prompt, tools, and budget.

  Useful for delegating a bounded task (exploring a codebase, summarising a
  file) to a fresh conversation with its own message history — so the parent
  loop doesn't pay the token cost of the sub-task's intermediate steps.

  Arguments:

    * `prompt` (required) — the sub-agent's opening message.
    * `agent` (optional) — name of an `ExAthena.Agents` definition (e.g.
      `"explore"`). The definition's `model`, `provider`, `tools`,
      `permissions`, `mode`, `isolation`, and system-prompt body apply
      automatically; explicit args still override.
    * `tools` (optional) — list of tool names to expose to the sub-agent; defaults
      to whatever the parent had (minus PlanMode + SpawnAgent to avoid loops).
    * `max_iterations` (optional, default 25, floored UP to 25) — worker loop budget.
    * `system_prompt` (optional) — system prompt override for the sub-agent.

  Workers ALWAYS run in the parent's working directory — there is no
  model-facing cwd arg (models passed junk paths and workers explored the
  wrong project). Hosts may still override via
  `ctx.assigns[:spawn_agent_opts][:cwd]`.

  Inherits the parent's provider / model / permissions unless overridden in
  `ctx.assigns[:spawn_agent_opts]`.

  ## Guardrail inheritance

  A child is never MORE privileged than its parent: the parent's
  confinement roots, `disallowed_tools` / `allowed_tools`, `can_use_tool`
  approval callback, phase, and deny-capable `PreToolUse` hooks are clamped
  onto every spawn. Agent definitions and model args may narrow these
  further but can never widen them — see `inherit_guardrails/2` for the
  exact combination rules and `docs/13-agents-and-subagents.md` for the
  policy.

  ## Worktree isolation

  When the chosen agent definition declares `isolation: :worktree` and the
  parent's cwd is a clean git repo with `git` on PATH, the subagent runs
  in a freshly-created worktree under `~/.cache/ex_athena/worktrees/<sess>/<name>-<n>`.
  If safety checks fail, the subagent transparently falls back to
  `:in_process` — no error.
  """

  alias ExAthena.Agents
  alias ExAthena.Agents.{Sidechain, Worktree}

  @behaviour ExAthena.Tool

  # One tool call ≈ one iteration on local models. 25 turns (user-tuned):
  # with tool-output caps + the Completed/Remaining failure handoff, a
  # worker that runs out hands its progress to a narrower retry instead of
  # burning an hour spinning. Smaller explicit args are floored UP.
  @default_max_iterations 25

  @impl true
  def name, do: "spawn_agent"

  # Workers run SERIALLY within a turn: the concurrent path would subject a
  # spawn to the per-tool timeout (tool_timeout_ms, default 60s) and kill
  # legitimate multi-minute workers mid-task (observed live as a run crash).
  # SpawnAgent manages its own generous timeout via Task.yield, and on
  # single-slot local providers concurrent workers would serialize at the
  # GPU gate anyway. Revisit per-tool timeouts if multi-slot fan-out lands.
  @impl true
  def parallel_safe?, do: false

  @impl true
  def description,
    do:
      "Run a synchronous sub-agent with its own fresh conversation to accomplish a focused sub-task. Returns the sub-agent's final text."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        prompt: %{type: "string"},
        agent: %{
          type: "string",
          description: "Name of an agent definition (e.g. \"explore\", \"plan\"). Optional."
        },
        tools: %{type: "array", items: %{type: "string"}},
        max_iterations: %{type: "integer"},
        system_prompt: %{type: "string"},
        todo: %{
          type: "string",
          description:
            "Exact content of the todo item this sub-agent works on. When the sub-agent succeeds, that todo is marked completed automatically."
        },
        objective: %{
          type: "string",
          description: "What the worker must accomplish."
        },
        expected_output: %{
          type: "string",
          description: "Exactly what the worker should return."
        },
        tool_guidance: %{
          type: "string",
          description: "Which tools/sources to use."
        },
        boundaries: %{
          type: "string",
          description: "What is out of scope / must not be touched."
        },
        max_result_chars: %{
          type: "integer",
          description: "Truncate the sub-agent's returned summary to this many characters."
        }
      },
      required: ["prompt"]
    }
  end

  # Task brief for strict spawns (orchestrate mode). NOTHING is rejected —
  # live testing showed every rejection class just burns turns (small models
  # repeat the identical invalid call verbatim instead of repairing). Every
  # missing field gets a runtime default; the brief is enrichment when the
  # model provides it, never a wall.
  @brief_defaults %{
    "expected_output" =>
      "a self-contained summary (max 300 words) of findings, decisions, and files changed",
    "tool_guidance" => "Use any available tools as needed.",
    "boundaries" => "Do only this step; do not start or modify anything outside its scope."
  }
  @brief_fields ~w(objective expected_output tool_guidance boundaries)

  # Max agent nesting depth (0 = main/orchestrator, 1 = its workers, 2+ =
  # nested). High by default so workers can delegate sub-tasks, but bounded —
  # see the depth rail in execute/2.
  @default_max_agent_depth 5

  @impl true
  def execute(%{"prompt" => prompt} = args, ctx) when is_binary(prompt) do
    assigns = ctx.assigns || %{}
    todo = Map.get(args, "todo")

    cond do
      Map.get(assigns, :agent_depth, 0) >= max_agent_depth(assigns) ->
        # Nesting-depth rail: agents may delegate sub-agents up to a
        # configurable max depth (config :ex_athena, max_agent_depth, default
        # #{@default_max_agent_depth}; per-run via assigns[:max_agent_depth]).
        # A hard ceiling is kept on purpose — on a single GPU slot an unbounded
        # worker tree serializes through one queue and a degenerate model could
        # spawn forever.
        {:error,
         "maximum nesting depth (#{max_agent_depth(assigns)}) reached: " <>
           "finish this step yourself and report back"}

      is_binary(todo) and MapSet.member?(Map.get(assigns, :completed_todos, MapSet.new()), todo) ->
        # Don't-repeat-steps rail: a completed todo must never re-run a
        # 30-min worker. Short-circuit instantly.
        {:error,
         "Step #{inspect(todo)} is already complete — do not re-run it. " <>
           "Build on the recorded findings and move to the next pending todo."}

      true ->
        do_execute(fill_brief_defaults(args, ctx), prompt, ctx)
    end
  end

  def execute(_, _), do: {:error, :missing_prompt}

  defp do_execute(args, prompt, ctx) do
    # 30 min wall clock — covers the 25-iteration budget on a local model
    # at 30–90s/turn plus single-slot queue waits. NOT model-controllable:
    # small models supplied self-sabotaging 30–60s budgets that killed the
    # worker after one turn (same lesson as cwd). Host override only, via
    # spawn_agent_opts[:timeout_ms].
    timeout =
      case (ctx.assigns[:spawn_agent_opts] || [])[:timeout_ms] do
        n when is_integer(n) and n > 0 -> n
        _ -> 1_800_000
      end

    prompt = compose_worker_prompt(prompt, args, ctx.cwd)

    {agent_def, base_opts} = resolve_agent(args, ctx)

    sub_id = "subagent_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

    # The child sits one level below us; it may itself delegate only while it
    # stays under the cap (else its spawn_agent tool would just be a blocked
    # schema burning prompt tokens).
    child_depth = Map.get(ctx.assigns || %{}, :agent_depth, 0) + 1
    child_can_nest? = child_depth < max_agent_depth(ctx.assigns || %{})

    sub_opts =
      base_opts
      |> Keyword.put_new(:max_iterations, worker_iterations(Map.get(args, "max_iterations")))
      # The worker's per-REQUEST timeout defaults to the spawn timeout —
      # the 60s Request default became receive_timeout and killed workers
      # whose grown prompts made local backends prompt-process >60s before
      # the first streamed byte ("Stream failed: :timeout").
      |> Keyword.put_new(:timeout_ms, timeout)
      |> maybe_put(:system_prompt, Map.get(args, "system_prompt"))
      |> Keyword.put(
        :tools,
        resolve_tools(Map.get(args, "tools"), agent_def && agent_def.tools, child_can_nest?)
      )
      |> apply_prompt_suffix(ctx)
      |> attribute_events(sub_id, ctx, args, agent_def, child_depth)
      |> Keyword.put(:parent_session_id, ctx.session_id)
      |> inherit_guardrails(ctx)

    # Worktree isolation lives between resolving the agent and starting the
    # sub-loop so the sub-loop's `:cwd` becomes the worktree path. Falls back
    # to the parent's cwd transparently if any safety check fails.
    {sub_opts, isolation_info} = apply_isolation(agent_def, sub_opts, ctx)

    parent_hooks = Map.get(ctx.assigns || %{}, :hooks, %{})

    emit_event(ctx, {:subagent_spawn, %{id: sub_id, prompt: prompt}})

    _ =
      ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStart, %{
        subagent_id: sub_id,
        prompt: prompt,
        parent_session_id: ctx.session_id,
        agent: agent_def && agent_def.name,
        isolation: isolation_info
      })

    ExAthena.Telemetry.event(
      [:ex_athena, :subagent, :spawn],
      %{},
      %{
        subagent_id: sub_id,
        parent_conversation_id: Map.get(ctx.assigns || %{}, :conversation_id)
      }
    )

    # Run the sub-loop under a supervised Task so a crash doesn't bring
    # down the parent, and timeouts are enforceable. Task.Supervisor is
    # started by ExAthena.Application under `ExAthena.Tasks`.
    task =
      Task.Supervisor.async_nolink(ExAthena.Tasks, fn ->
        ExAthena.Loop.run(prompt, sub_opts)
      end)

    raw_result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    # Persist the sidechain transcript (best-effort; never fails the spawn).
    _ =
      Sidechain.write(%{
        cwd: Keyword.get(sub_opts, :cwd, ctx.cwd),
        parent_session_id: ctx.session_id || "unknown",
        subagent_id: sub_id,
        prompt: prompt,
        opts: sub_opts,
        result:
          case raw_result do
            {:ok, r} -> r
            other -> other
          end
      })

    finalized_isolation = finalize_isolation(isolation_info)

    result =
      case raw_result do
        # The sub-loop ALWAYS returns a Result, including error terminations
        # (error_max_turns, error_no_progress, …). An unfinished worker must
        # surface as a tool ERROR — returning its (usually empty) text as a
        # success left the orchestrator blind to the failure.
        {:ok, {:ok, %ExAthena.Result{} = sub_result}}
        when sub_result.finish_reason not in [:stop, :submitted] ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :incomplete,
              result: sub_result,
              isolation: finalized_isolation
            })

          digest = conclusions_digest(sub_result)

          # Surface the failure digest on the agent's Overview entry too.
          case Map.get(ctx.assigns || %{}, :agent_event_sink) do
            sink when is_function(sink, 2) ->
              sink.(
                sub_id,
                {:result_note, "did not finish (#{sub_result.finish_reason}):\n#{digest}"}
              )

            _ ->
              :ok
          end

          {:error,
           "worker did not finish (#{sub_result.finish_reason}). " <>
             "What it learned before stopping:\n#{digest}\n" <>
             "Re-delegate with a narrower or clearer brief, building on those findings."}

        {:ok, {:ok, %{text: text} = sub_result}} ->
          # A thinking-model worker often ends with a BLANK text channel —
          # its report (and a `finish` deliverable) may be empty while all
          # the findings live in its conclusions ledger (the captured
          # <think> blobs). Fall back text → deliverable → conclusions so
          # the orchestrator never receives an empty summary for real work.
          text =
            cond do
              not blank?(text) -> text
              d = deliverable_text(sub_result) -> d
              true -> conclusions_digest(sub_result)
            end

          text = truncate_result(text, Map.get(args, "max_result_chars") || 8_000)
          emit_event(ctx, {:subagent_result, %{id: sub_id, text: text}})

          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :ok,
              result: sub_result,
              isolation: finalized_isolation
            })

          ExAthena.Telemetry.event(
            [:ex_athena, :subagent, :stop],
            %{},
            %{subagent_id: sub_id, outcome: :ok}
          )

          ui = subagent_ui(sub_id, sub_result, finalized_isolation)
          {:ok, text, ui}

        {:ok, {:error, reason}} ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :error,
              reason: reason,
              isolation: finalized_isolation
            })

          {:error, {:sub_agent_failed, reason}}

        {:exit, reason} ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :crash,
              reason: reason,
              isolation: finalized_isolation
            })

          notify_failure(ctx, sub_id, "crashed: #{inspect(reason)}")
          {:error, {:sub_agent_crashed, reason}}

        nil ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :timeout,
              isolation: finalized_isolation
            })

          notify_failure(ctx, sub_id, "timed out after #{timeout}ms — progress discarded")
          {:error, {:sub_agent_timeout, timeout}}
      end

    result
  end

  # Killed/crashed workers never emit their own {:done} — without this the
  # Overview row stays RUNNING until the whole run ends.
  defp notify_failure(ctx, sub_id, text) do
    case Map.get(ctx.assigns || %{}, :agent_event_sink) do
      sink when is_function(sink, 2) ->
        sink.(sub_id, {:result_note, text})
        sink.(sub_id, {:done, %ExAthena.Result{finish_reason: :error_during_execution}})

      _ ->
        :ok
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # ── Parent guardrail inheritance (issue #130) ─────────────────────
  #
  # SECURITY INVARIANT: a child may be NARROWER than its parent but never
  # MORE privileged. Agent definitions and model-supplied args can restrict
  # a worker further; nothing they say can escape the parent's confinement
  # roots, tool deny/allow lists, approval callback, phase, or PreToolUse
  # deny hooks. Concretely:
  #
  #   * allowed_roots — a confined parent confines every child. A requested
  #     root survives only if it lies inside a parent root (intersection);
  #     otherwise the child gets the parent's roots verbatim. (The child
  #     loop still cwd-anchors its roots, so a worktree-isolated child can
  #     reach its own worktree — that is the one deliberate widening, and it
  #     is host-controlled, never model-controlled.)
  #   * disallowed_tools — union of parent's and child's (deny always wins).
  #   * allowed_tools — intersection when both exist; parent's when only the
  #     parent has one.
  #   * can_use_tool — inherited unless the HOST already supplied one via
  #     spawn_agent_opts (the host is trusted; the model cannot set this).
  #   * phase — clamped to the more restrictive of parent's and requested
  #     (see Permissions.most_restrictive_phase/2). A :plan parent can only
  #     spawn :plan children; a definition may still narrow (:default parent
  #     → :plan child).
  #   * hooks — ONLY the parent's PreToolUse groups are inherited (they are
  #     part of the permission gate). Other hook events are deliberately NOT
  #     inherited: they may assume parent context (Stop hooks persisting
  #     parent session state, SessionEnd cleanup, …). Hosts wanting full
  #     hook inheritance can pass a hooks table in spawn_agent_opts.
  defp inherit_guardrails(sub_opts, ctx) do
    assigns = ctx.assigns || %{}
    parent_perms = Map.get(assigns, :run_permissions) || %{}

    sub_opts
    |> inherit_confinement(ctx.allowed_roots)
    |> clamp_phase(ctx.phase)
    |> union_disallowed(parent_perms[:disallowed_tools])
    |> intersect_allowed(parent_perms[:allowed_tools])
    |> inherit_can_use_tool(parent_perms[:can_use_tool])
    |> inherit_pre_tool_hooks(Map.get(assigns, :hooks) || %{})
  end

  defp inherit_confinement(sub_opts, nil), do: sub_opts

  defp inherit_confinement(sub_opts, parent_roots) do
    requested =
      sub_opts
      |> Keyword.get(:allowed_roots)
      |> List.wrap()
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&ExAthena.ToolContext.within_roots?(&1, parent_roots))

    roots = if requested == [], do: parent_roots, else: requested

    sub_opts
    |> Keyword.put(:allowed_roots, roots)
    |> Keyword.delete(:confine)
  end

  defp clamp_phase(sub_opts, parent_phase) do
    requested = Keyword.get(sub_opts, :phase, parent_phase)

    Keyword.put(
      sub_opts,
      :phase,
      ExAthena.Permissions.most_restrictive_phase(requested, parent_phase)
    )
  end

  defp union_disallowed(sub_opts, nil), do: sub_opts

  defp union_disallowed(sub_opts, parent_list) when is_list(parent_list) do
    merged =
      sub_opts
      |> Keyword.get(:disallowed_tools)
      |> List.wrap()
      |> Kernel.++(parent_list)
      |> Enum.uniq()

    Keyword.put(sub_opts, :disallowed_tools, merged)
  end

  defp intersect_allowed(sub_opts, nil), do: sub_opts

  defp intersect_allowed(sub_opts, parent_list) when is_list(parent_list) do
    child =
      case Keyword.get(sub_opts, :allowed_tools) do
        nil -> parent_list
        list when is_list(list) -> Enum.filter(list, &(&1 in parent_list))
      end

    Keyword.put(sub_opts, :allowed_tools, child)
  end

  defp inherit_can_use_tool(sub_opts, nil), do: sub_opts

  defp inherit_can_use_tool(sub_opts, fun) when is_function(fun, 3),
    do: Keyword.put_new(sub_opts, :can_use_tool, fun)

  defp inherit_pre_tool_hooks(sub_opts, parent_hooks) do
    case Map.get(parent_hooks, :PreToolUse) do
      groups when is_list(groups) and groups != [] ->
        child_hooks = Keyword.get(sub_opts, :hooks) || %{}
        merged = Map.update(child_hooks, :PreToolUse, groups, &(&1 ++ groups))
        Keyword.put(sub_opts, :hooks, merged)

      _ ->
        sub_opts
    end
  end

  # In strict mode, every omitted brief field gets a runtime default so the
  # worker contract stays complete without forcing a small model to produce
  # every field. The objective falls back to the prompt itself.
  defp fill_brief_defaults(args, ctx) do
    if Map.get(ctx.assigns || %{}, :strict_spawn, false) do
      args =
        if blank?(Map.get(args, "objective")) do
          Map.put(args, "objective", truncate_result(Map.get(args, "prompt", ""), 200))
        else
          args
        end

      Enum.reduce(@brief_defaults, args, fn {field, default}, acc ->
        if blank?(Map.get(acc, field)), do: Map.put(acc, field, default), else: acc
      end)
    else
      args
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Fold the brief into the worker's opening message so it is self-contained.
  defp compose_worker_prompt(prompt, args, cwd) do
    brief =
      @brief_fields
      |> Enum.map(fn f -> {f, Map.get(args, f)} end)
      |> Enum.reject(fn {_f, v} -> blank?(v) end)
      |> Enum.map_join("\n", fn {f, v} ->
        "#{f |> String.replace("_", " ") |> String.capitalize()}: #{v}"
      end)

    # Pin the worker to the parent's project explicitly — paths in the brief
    # are relative to it, and the worker must never wander elsewhere.
    brief = append_cwd_line(brief, cwd)

    if brief == "" do
      prompt
    else
      prompt <> "\n\n## Task brief\n" <> brief
    end
  end

  # Orchestrating parents (see Loop's :subagent_prompt_suffix opt) append a
  # worker contract to every sub-agent's system prompt.
  defp apply_prompt_suffix(sub_opts, %{assigns: %{subagent_prompt_suffix: suffix}})
       when is_binary(suffix) and suffix != "" do
    case Keyword.get(sub_opts, :system_prompt) do
      nil -> Keyword.put(sub_opts, :system_prompt, suffix)
      existing -> Keyword.put(sub_opts, :system_prompt, existing <> "\n\n" <> suffix)
    end
  end

  defp apply_prompt_suffix(sub_opts, _ctx), do: sub_opts

  # Per-agent attribution (see ExAthena.Orchestrator.Coordinator): when the
  # parent run carries an :agent_event_sink, the sub-loop's events flow
  # through it tagged with this sub_id — its own on_event, its own
  # todo_writer, and an :agent_meta enrichment (name, linked todo, parent id,
  # depth). The sink is KEPT (not deleted) so a nested grandchild's events
  # still reach the top-level coordinator; on_event/todo_writer are re-tagged
  # at each level so attribution stays correct. `current_agent_id` records who
  # this child is, so ITS children can name it as their parent.
  defp attribute_events(
         sub_opts,
         sub_id,
         %{assigns: %{agent_event_sink: sink}} = ctx,
         args,
         agent_def,
         child_depth
       )
       when is_function(sink, 2) do
    sink.(
      sub_id,
      {:agent_meta,
       %{
         prompt: Map.get(args, "prompt"),
         name: agent_def && agent_def.name,
         linked_todo: Map.get(args, "todo"),
         parent_id: Map.get(ctx.assigns, :current_agent_id, :main),
         depth: child_depth
       }}
    )

    tagged_on_event = fn event -> sink.(sub_id, event) end

    todo_writer = fn todos ->
      sink.(sub_id, {:todos, todos})
      :ok
    end

    sub_assigns =
      ctx.assigns
      |> Map.put(:on_event, tagged_on_event)
      |> Map.put(:todo_writer, todo_writer)
      |> Map.put(:agent_depth, child_depth)
      |> Map.put(:current_agent_id, sub_id)

    sub_opts
    |> Keyword.put(:on_event, tagged_on_event)
    |> Keyword.put(:assigns, sub_assigns)
  end

  defp attribute_events(sub_opts, sub_id, ctx, _args, _agent_def, child_depth) do
    sub_assigns =
      (ctx.assigns || %{})
      |> Map.put(:agent_depth, child_depth)
      |> Map.put(:current_agent_id, sub_id)

    Keyword.put(sub_opts, :assigns, sub_assigns)
  end

  defp deliverable_text(%ExAthena.Result{deliverable: d}) when is_binary(d) and d != "", do: d
  defp deliverable_text(_), do: nil

  defp append_cwd_line(brief, cwd) when is_binary(cwd) and cwd != "" do
    line =
      "Working directory: #{cwd} — all paths are relative to this project; never work outside it."

    if brief == "", do: line, else: brief <> "\n" <> line
  end

  defp append_cwd_line(brief, _cwd), do: brief

  # Salvage an unfinished worker's learnings: its conclusions ledger (and
  # any final text) as a compact digest the orchestrator can build on.
  # Structured handoff so the retry skips finished work: completed and
  # remaining sub-todos, plus the worker's STATED findings (derived
  # "ran bash" noise only as a last resort).
  defp conclusions_digest(%ExAthena.Result{} = sub_result) do
    {completed, remaining} =
      Enum.split_with(sub_result.todos, fn t ->
        (t["status"] || t[:status]) in ["completed", :completed]
      end)

    findings =
      case Enum.filter(sub_result.conclusions, &(&1.source == :stated)) do
        [] -> Enum.take(sub_result.conclusions, -3)
        stated -> Enum.take(stated, -3)
      end

    text = String.trim(sub_result.text || "")

    sections =
      [
        section("Completed", completed, "✔"),
        section("Remaining", remaining, "◻"),
        case findings do
          [] -> nil
          fs -> "Findings:\n" <> Enum.map_join(fs, "\n", &"- #{&1.text}")
        end,
        if(text != "", do: truncate_result(text, 300))
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> "(nothing recorded)"
      _ -> Enum.join(sections, "\n")
    end
  end

  defp section(_label, [], _marker), do: nil

  defp section(label, todos, marker) do
    items = Enum.map_join(todos, " ", fn t -> "#{marker} #{t["content"] || t[:content]}" end)
    "#{label}: #{items}"
  end

  defp truncate_result(text, max) when is_integer(max) and max > 0 do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp truncate_result(text, _), do: text

  # Worker iteration caps chosen by the model are floored at the default —
  # live testing showed an orchestrator starving its worker with
  # max_iterations: 5 (the worker died at error_max_turns mid-task).
  defp worker_iterations(n) when is_integer(n), do: max(n, @default_max_iterations)
  defp worker_iterations(_), do: @default_max_iterations

  # Pass names through; the loop resolves names → modules. Filter out the
  # meta tools (runaway recursion) AND any name that isn't a known tool —
  # models invent shell-command names ("ls", "tree") which used to raise in
  # the sub-loop's tool resolution and crash the worker. An empty result
  # falls back to nil (inherit the default toolset).
  # Default worker toolset = all builtins MINUS the loop-control tools:
  # Effective worker toolset.
  #
  # The agent definition's declared `tools` are the CEILING — a restricted
  # agent (e.g. `explore`, read-only) must stay restricted, so we never widen
  # past what it declared. A model-supplied `tools` arg may NARROW within that
  # ceiling but can never add a tool the agent isn't allowed. With no agent
  # definition (plain spawn), the ceiling is the full builtin set.
  #
  # Control tools (`plan_mode` / `spawn_agent`) are never inherited from the
  # ceiling. `todo_write` is always granted (worker contract). `spawn_agent` is
  # granted only when the child is allowed to nest further (depth < cap), so
  # any worker can delegate sub-tasks until the ceiling — see the depth rail.
  defp resolve_tools(requested, declared, child_can_nest?) do
    known = ExAthena.Tools.builtins() |> MapSet.new(& &1.name())
    all = Enum.map(ExAthena.Tools.builtins(), & &1.name())

    ceiling = if is_list(declared), do: declared, else: all

    selected =
      case requested do
        list when is_list(list) -> Enum.filter(list, &(&1 in ceiling))
        _ -> ceiling
      end

    selected
    |> Enum.reject(&(&1 in ["plan_mode", "spawn_agent"]))
    |> Enum.filter(&MapSet.member?(known, &1))
    |> maybe_grant("todo_write", true)
    |> maybe_grant("spawn_agent", child_can_nest?)
  end

  defp maybe_grant(tools, _name, false), do: tools
  defp maybe_grant(tools, name, true), do: if(name in tools, do: tools, else: tools ++ [name])

  defp max_agent_depth(assigns) do
    Map.get(assigns, :max_agent_depth) ||
      Application.get_env(:ex_athena, :max_agent_depth, @default_max_agent_depth)
  end

  defp emit_event(%{assigns: %{on_event: callback}}, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end

  defp emit_event(_ctx, _event), do: :ok

  # ── Agent + isolation resolution ──────────────────────────────────

  defp resolve_agent(args, ctx) do
    # Workers ALWAYS run in the parent's project directory. A model-facing
    # cwd arg used to exist here — live testing showed models passing junk
    # paths and workers exploring the wrong project entirely. Host-level
    # overrides via spawn_agent_opts[:cwd] still win (put_new below).
    base_opts =
      (ctx.assigns[:spawn_agent_opts] || [])
      |> Keyword.put_new(:cwd, ctx.cwd)

    case Map.get(args, "agent") do
      nil ->
        {nil, base_opts}

      name when is_binary(name) ->
        agents = Map.get(ctx.assigns || %{}, :agents) || Agents.discover(ctx.cwd)

        case Agents.fetch(agents, name) do
          {:ok, def} -> {def, Agents.apply_to_opts(def, base_opts)}
          {:error, :not_found} -> {nil, base_opts}
        end
    end
  end

  defp apply_isolation(nil, opts, _ctx), do: {opts, nil}

  defp apply_isolation(def, opts, ctx) do
    case Worktree.resolve(def, ctx.cwd, ctx.session_id || "session") do
      {:worktree, info} ->
        {Keyword.put(opts, :cwd, info.path), {:worktree, info}}

      {:in_process, reason} ->
        {opts, {:in_process, reason}}
    end
  end

  defp finalize_isolation({:worktree, info}) do
    case Worktree.finalize(info) do
      {:kept, kept} -> {:worktree_kept, kept}
      {:removed, removed} -> {:worktree_removed, removed}
      {:error, reason} -> {:worktree_error, Map.put(info, :reason, reason)}
    end
  end

  defp finalize_isolation(other), do: other

  defp subagent_ui(sub_id, sub_result, isolation) do
    payload = %{
      subagent_id: sub_id,
      iterations: Map.get(sub_result, :iterations),
      tool_calls_made: Map.get(sub_result, :tool_calls_made),
      cost_usd: Map.get(sub_result, :cost_usd),
      duration_ms: Map.get(sub_result, :duration_ms),
      isolation: isolation
    }

    %{kind: :subagent, payload: payload}
  end
end
