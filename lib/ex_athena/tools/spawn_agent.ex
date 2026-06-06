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
    * `max_iterations` (optional, default 10) — cap on agent-loop iterations.
    * `system_prompt` (optional) — system prompt override for the sub-agent.
    * `cwd` (optional) — working directory for the sub-agent. Defaults to the
      parent's cwd. Useful when delegating work on a different project so the
      sub-agent loads the correct `AGENTS.md` and operates in the right tree.

  Inherits the parent's provider / model / permissions unless overridden in
  `ctx.assigns[:spawn_agent_opts]`.

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

  # One tool call ≈ one iteration on local models — 10 turns starved real
  # exploration tasks (observed: error_max_turns at 10 with the worker mid-
  # task). Match the kernel's default; the worker's no-progress guard is the
  # runaway protection.
  @default_max_iterations 25

  @impl true
  def name, do: "spawn_agent"

  # Subagents are independent loops; the request queue serializes their
  # provider calls on scarce GPU slots, so spawning several in one turn is
  # safe — Parallel.run caps concurrency via state.max_concurrency.
  @impl true
  def parallel_safe?, do: true

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
        cwd: %{
          type: "string",
          description:
            "Working directory for the sub-agent. Defaults to the parent's cwd. Use this to point the sub-agent at a different project directory."
        },
        todo: %{
          type: "string",
          description:
            "Exact content of the todo item this sub-agent works on. When the sub-agent succeeds, that todo is marked completed automatically."
        },
        objective: %{
          type: "string",
          description: "What the worker must accomplish (required in orchestrate mode)."
        },
        expected_output: %{
          type: "string",
          description: "Exactly what the worker should return (required in orchestrate mode)."
        },
        tool_guidance: %{
          type: "string",
          description: "Which tools/sources to use (required in orchestrate mode)."
        },
        boundaries: %{
          type: "string",
          description:
            "What is out of scope / must not be touched (required in orchestrate mode)."
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

  @impl true
  def execute(%{"prompt" => prompt} = args, ctx) when is_binary(prompt) do
    if Map.get(ctx.assigns || %{}, :subagent?, false) do
      # Depth-1 rail (Claude Code's own rule): workers finish their step and
      # report back — they never spawn further workers.
      {:error,
       "nested subagents are not allowed (depth 1): finish this step yourself and report back"}
    else
      do_execute(fill_brief_defaults(args, ctx), prompt, ctx)
    end
  end

  def execute(_, _), do: {:error, :missing_prompt}

  defp do_execute(args, prompt, ctx) do
    timeout = Map.get(args, "timeout_ms", 300_000)
    prompt = compose_worker_prompt(prompt, args)

    {agent_def, base_opts} = resolve_agent(args, ctx)

    sub_id = "subagent_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

    sub_opts =
      base_opts
      |> Keyword.put_new(:max_iterations, worker_iterations(Map.get(args, "max_iterations")))
      |> maybe_put(:system_prompt, Map.get(args, "system_prompt"))
      |> maybe_put(:tools, resolve_tools(Map.get(args, "tools"), ctx))
      |> apply_prompt_suffix(ctx)
      |> attribute_events(sub_id, ctx, args, agent_def)
      |> Keyword.put(:parent_session_id, ctx.session_id)

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

          {:error,
           "worker did not finish (#{sub_result.finish_reason}). " <>
             "Partial output: #{sub_result.text || "(none)"}. " <>
             "Re-delegate with a narrower or clearer brief."}

        {:ok, {:ok, %{text: text} = sub_result}} ->
          text = truncate_result(text || "", Map.get(args, "max_result_chars"))
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

          {:error, {:sub_agent_crashed, reason}}

        nil ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :timeout,
              isolation: finalized_isolation
            })

          {:error, {:sub_agent_timeout, timeout}}
      end

    result
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

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
  defp compose_worker_prompt(prompt, args) do
    brief =
      @brief_fields
      |> Enum.map(fn f -> {f, Map.get(args, f)} end)
      |> Enum.reject(fn {_f, v} -> blank?(v) end)
      |> Enum.map_join("\n", fn {f, v} ->
        "#{f |> String.replace("_", " ") |> String.capitalize()}: #{v}"
      end)

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
  # todo_writer, and an :agent_meta enrichment (name + linked todo). The
  # sink and parent callbacks are OVERWRITTEN (not put_new) in the sub
  # assigns so nested spawns can never mis-attribute to this level, and the
  # sink itself is removed (depth-1 observation).
  defp attribute_events(
         sub_opts,
         sub_id,
         %{assigns: %{agent_event_sink: sink}} = ctx,
         args,
         agent_def
       )
       when is_function(sink, 2) do
    sink.(
      sub_id,
      {:agent_meta,
       %{
         prompt: Map.get(args, "prompt"),
         name: agent_def && agent_def.name,
         linked_todo: Map.get(args, "todo")
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
      |> Map.put(:subagent?, true)
      |> Map.delete(:agent_event_sink)

    sub_opts
    |> Keyword.put(:on_event, tagged_on_event)
    |> Keyword.put(:assigns, sub_assigns)
  end

  defp attribute_events(sub_opts, _sub_id, ctx, _args, _agent_def) do
    Keyword.put(sub_opts, :assigns, Map.put(ctx.assigns, :subagent?, true))
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
  defp resolve_tools(nil, _ctx), do: nil

  defp resolve_tools(names, _ctx) when is_list(names) do
    known = ExAthena.Tools.builtins() |> MapSet.new(& &1.name())

    names
    |> Enum.reject(&(&1 in ["plan_mode", "spawn_agent"]))
    |> Enum.filter(&MapSet.member?(known, &1))
    |> case do
      [] -> nil
      filtered -> filtered
    end
  end

  defp emit_event(%{assigns: %{on_event: callback}}, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end

  defp emit_event(_ctx, _event), do: :ok

  # ── Agent + isolation resolution ──────────────────────────────────

  defp resolve_agent(args, ctx) do
    effective_cwd = Map.get(args, "cwd") || ctx.cwd

    base_opts =
      (ctx.assigns[:spawn_agent_opts] || [])
      |> Keyword.put_new(:cwd, effective_cwd)

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
