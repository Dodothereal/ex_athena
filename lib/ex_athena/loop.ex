defmodule ExAthena.Loop do
  @moduledoc """
  Agent-loop kernel. Dispatches to a `ExAthena.Loop.Mode` implementation
  and handles everything around it: caps, budget, hooks, counters, events,
  and termination accounting.

  Public entry point: `run/2`, returning `{:ok, %ExAthena.Result{}} |
  {:error, reason}`.

  ## v0.3 breaking change

  The return shape is now an `ExAthena.Result` struct instead of a loose
  map. Every termination — success or error — produces a Result with the
  typed `finish_reason` (see `ExAthena.Loop.Terminations` for the
  enumeration). Callers can dispatch on `Result.category/1`
  (`:success | :retryable | :capacity | :fatal`) instead of pattern-matching
  individual atoms.

  ## Options

    * `:provider` — required. Provider atom (`:ollama`, `:openai`,
      `:claude`, `:mock`, `:req_llm`) or a module implementing
      `ExAthena.Provider`.
    * `:model`, `:system_prompt`, `:messages`, `:temperature`, `:top_p`,
      `:max_tokens`, `:stop`, `:timeout_ms`, `:tool_choice`,
      `:response_format`, `:provider_opts`, `:metadata`, `:images` —
      forwarded to `ExAthena.Request.new/2`. See `ExAthena.query/2` for
      the `:images` shorthand (inline and URL images).
    * `:tools` — list of modules implementing `ExAthena.Tool` or `:all`
      (default — all builtins). `nil` falls back to `config :ex_athena,
      tools: …`.
    * `:mode` — atom (`:react`, `:plan_and_solve`, `:reflexion`) or module.
      Defaults to `:react`.
    * `:cwd`, `:phase`, `:assigns` — threaded into every tool's
      `ExAthena.ToolContext`.
    * `:allow_local_hosts` (default `false`) — let `web_fetch` reach
      loopback/private/link-local hosts. By default those are refused (SSRF
      guard) even when the run is unconfined; see
      `ExAthena.Tools.WebFetch`.
    * `:allowed_tools`, `:disallowed_tools`, `:readonly_tools`,
      `:can_use_tool` — see `ExAthena.Permissions`. `:readonly_tools`
      names extra tools the read-only `:plan` phase may run (merged with
      tools that declare `read_only?/0` / MCP `readOnlyHint`).
    * `:hooks` — see `ExAthena.Hooks`.
    * `:max_iterations` (default 25) — hard iteration cap. Pass `:infinity`
      to disable it (the no-progress guard, mistake counter, and budget cap
      still bound the run). The `:orchestrate` mode defaults to `:infinity`
      unless an explicit cap is passed.
    * `:max_consecutive_mistakes` (default 3) — counter threshold at
      which the loop terminates with `:error_consecutive_mistakes`.
    * `:max_unproductive_iterations` (default 3) — consecutive-iteration
      cap for detecting loops with no new tool name+args or assistant text.
      Trips `:error_no_progress` before `:error_max_turns` fires. Pass
      `0` to disable the guard.
    * `:max_budget_usd` — optional float. Trips
      `:error_max_budget_usd` when cumulative cost crosses it.
    * `:tool_timeout_ms` (default 60_000) — per-call timeout for parallel
      tool execution.
    * `:max_concurrency` (default 4) — `Task.async_stream` concurrency
      cap for parallel-safe tool calls in a single iteration.
    * `:on_event` — `(ExAthena.Loop.Events.t -> term)` callback for
      streaming. Events are flat tuples (`{:content, text}`,
      `{:tool_call, tc}`, `{:tool_result, tr}`, `{:iteration, n}`,
      `{:usage, u}`, `{:error, reason}`, `{:done, Result}`).
    * `:session_id` — stable identifier for this run. Threaded into the
      `ToolContext` and used by hooks / storage / sidechain transcripts.
      Auto-generated when omitted.
    * `:parent_session_id` — when this run is a subagent of another run,
      the parent's `session_id`. `nil` for top-level runs. Used by
      `ExAthena.Sessions.Stores.Jsonl` (PR5) to write subagent
      sidechains and by `ExAthena.Agents` (PR4) to scope worktrees.
    * `:memory` — `:auto` (default — discover `AGENTS.md`/`CLAUDE.md`
      from `cwd` and `~/.config/ex_athena/`), `false` (skip memory
      entirely), or an explicit list of `Message.t()` to prepend.
    * `:skills` — `:auto` (default — discover skills from
      `<cwd>/.exathena/skills/` and `~/.config/ex_athena/skills/`),
      `false` (skip), or an explicit `%{name => %Skill{}}` map.
    * `:preload_skills` — list of skill names whose bodies should be
      activated up-front (skips the `[skill: name]` sentinel
      round-trip).

  ## Returns

    * `{:ok, Result.t()}` — ran to termination (possibly with an error
      subtype like `:error_max_turns`; the Result contains the
      classification).
    * `{:error, reason}` — unexpected failure before the loop started
      (e.g. unknown provider, bad tool module).
  """

  alias ExAthena.{Budget, Config, Error, Memory, Request, Result, Skills, Telemetry, Tools}
  alias ExAthena.Loop.{Events, Mode, State}
  alias ExAthena.Lsp.ImplicitDiagnostics
  alias ExAthena.Messages.Message

  @default_max_iterations 25
  @default_max_mistakes 3
  @default_max_unproductive_iterations 3
  @default_max_concurrency 4
  @default_tool_timeout_ms 60_000

  @spec run(String.t() | nil, keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(prompt, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    meta =
      Telemetry.genai_meta(
        operation: "invoke_agent",
        provider: Keyword.get(opts, :provider),
        request_model: Keyword.get(opts, :model),
        agent_id: Keyword.get(opts, :agent_id),
        conversation_id: Keyword.get(opts, :conversation_id)
      )

    Telemetry.span([:ex_athena, :loop], meta, fn ->
      with {:ok, state} <- build_initial_state(prompt, opts),
           {:ok, state} <- state.mode.init(state) do
        state |> loop() |> to_result(started_at)
      end
    end)
  end

  # ── Loop body ─────────────────────────────────────────────────────

  defp loop(%State{} = state) do
    cond do
      reason = Map.get(state.meta, :early_halt) ->
        state
        |> Map.put(:halted_reason, reason)
        |> set_finish_reason(:error_halted)

      # :infinity disables the cap (orchestrate mode default) — the
      # no-progress guard, mistake counter, budget cap, and the host's stop
      # control bound the run instead.
      is_integer(state.max_iterations) and state.iterations >= state.max_iterations ->
        state
        |> set_finish_reason(:error_max_turns)

      state.consecutive_mistakes >= state.max_consecutive_mistakes ->
        state
        |> set_finish_reason(:error_consecutive_mistakes)

      Budget.exceeded?(state.budget, state.max_budget_usd) ->
        state
        |> set_finish_reason(:error_max_budget_usd)

      state.max_unproductive_iterations > 0 and
          state.unproductive_iterations >= state.max_unproductive_iterations ->
        snapshot = Enum.take(state.messages, -(state.max_unproductive_iterations * 4))

        %{state | no_progress_snapshot: snapshot}
        |> set_finish_reason(:error_no_progress)

      true ->
        case maybe_compact(state) do
          {:ok, state} ->
            Events.emit(state.on_event, {:iteration, state.iterations})

            case run_pre_iteration_hook(state) do
              {:halt, reason} ->
                state
                |> Map.put(:halted_reason, reason)
                |> set_finish_reason(:error_halted)

              {:ok, state} ->
                case state.mode.iterate(state) do
                  {:continue, new_state} ->
                    new_state = update_progress_tracking(state, new_state)
                    loop(%{new_state | iterations: new_state.iterations + 1})

                  {:halt, new_state} ->
                    new_state

                  {:error, :error_prompt_too_long} ->
                    handle_prompt_too_long(state)

                  {:error, reason} ->
                    state
                    |> Map.put(:halted_reason, reason)
                    |> set_finish_reason(:error_during_execution)
                end
            end

          {:error, reason} ->
            state
            |> Map.put(:halted_reason, reason)
            |> set_finish_reason(:error_compaction_failed)
        end
    end
  end

  # Reactive recovery on `:error_prompt_too_long`: run the compaction
  # pipeline forcing every stage, then retry the same iteration once.
  # If still too large (or compaction itself failed), terminate with
  # `:error_prompt_too_long` so the caller sees a typed capacity
  # failure rather than a noisy `:error_during_execution`.
  defp handle_prompt_too_long(state) do
    if Keyword.get(reactive_compact_opts(state), :enabled, true) do
      case force_compact(state) do
        {:ok, state} ->
          case state.mode.iterate(state) do
            {:continue, new_state} ->
              new_state = update_progress_tracking(state, new_state)
              loop(%{new_state | iterations: new_state.iterations + 1})

            {:halt, new_state} ->
              new_state

            {:error, _reason} ->
              state |> set_finish_reason(:error_prompt_too_long)
          end

        {:error, reason} ->
          state
          |> Map.put(:halted_reason, reason)
          |> set_finish_reason(:error_prompt_too_long)
      end
    else
      state |> set_finish_reason(:error_prompt_too_long)
    end
  end

  defp force_compact(%State{} = state) do
    state = apply_auto_pin(state)
    compactor = compactor_module(state)

    estimate = %{
      tokens: ExAthena.Compactor.estimate_tokens(state.messages, system_prompt(state)),
      max_tokens: state.capabilities[:max_tokens] || 128_000,
      force: true
    }

    if function_exported?(compactor, :run, 3) do
      case compactor.run(state, estimate, force: true) do
        {:compact, new_messages, metadata} ->
          new_budget = Map.get(metadata, :budget, state.budget)
          Events.emit(state.on_event, {:compaction, metadata})
          {:ok, %{state | messages: new_messages, budget: new_budget}}

        :skip ->
          {:ok, state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      # Legacy compactor without `run/3` — fall back to a single compact pass.
      case compactor.compact(state, estimate) do
        {:compact, new_messages, metadata} ->
          new_budget = Map.get(metadata, :budget, state.budget)
          Events.emit(state.on_event, {:compaction, metadata})
          {:ok, %{state | messages: new_messages, budget: new_budget}}

        :skip ->
          {:ok, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_auto_pin(%State{meta: meta, messages: messages} = state) do
    case Map.get(meta, :auto_pin) do
      %{tool_names: names} when is_list(names) and names != [] ->
        id_to_name =
          messages
          |> Enum.flat_map(fn
            %Message{role: :assistant, tool_calls: tcs} when is_list(tcs) ->
              Enum.map(tcs, &{&1.id, &1.name})

            _ ->
              []
          end)
          |> Map.new()

        # Build the set of tool_call_ids whose tool name is in the pinned names list.
        # Pinning both the tool-result message AND its paired assistant message prevents
        # Summary from dropping the tool_calls entry and producing an orphaned tool_result.
        matching_ids =
          id_to_name
          |> Enum.filter(fn {_id, name} -> name in names end)
          |> Enum.map(&elem(&1, 0))
          |> MapSet.new()

        new_messages =
          Enum.map(messages, fn
            %Message{role: :tool, tool_results: results} = msg when is_list(results) ->
              if Enum.any?(results, fn tr -> tr.tool_call_id in matching_ids end) do
                %{msg | pin: true}
              else
                msg
              end

            %Message{role: :assistant, tool_calls: tcs} = msg when is_list(tcs) ->
              if Enum.any?(tcs, fn tc -> tc.id in matching_ids end) do
                %{msg | pin: true}
              else
                msg
              end

            msg ->
              msg
          end)

        %{state | messages: new_messages}

      _ ->
        state
    end
  end

  defp reactive_compact_opts(%State{meta: meta}) do
    case Map.get(meta, :reactive_compact) do
      nil -> [enabled: true]
      false -> [enabled: false]
      true -> [enabled: true]
      kw when is_list(kw) -> kw
    end
  end

  # ── Compaction ────────────────────────────────────────────────────

  defp maybe_compact(%State{} = state) do
    compactor = compactor_module(state)

    estimate = %{
      tokens: ExAthena.Compactor.estimate_tokens(state.messages, system_prompt(state)),
      max_tokens: state.capabilities[:max_tokens] || 128_000
    }

    if function_exported?(compactor, :should_compact?, 2) and
         compactor.should_compact?(state, estimate) do
      _ = ExAthena.Hooks.run_lifecycle(state.hooks, :PreCompact, %{estimate: estimate})

      case compactor.compact(state, estimate) do
        {:compact, new_messages, metadata} ->
          new_budget = Map.get(metadata, :budget, state.budget)

          Events.emit(state.on_event, {:compaction, metadata})

          Telemetry.event(
            [:ex_athena, :compaction, :stop],
            %{
              before_tokens: Map.get(metadata, :before),
              after_tokens: Map.get(metadata, :after),
              dropped_count: Map.get(metadata, :dropped_count)
            },
            %{reason: Map.get(metadata, :reason)}
          )

          _ =
            ExAthena.Hooks.run_lifecycle(state.hooks, :PostCompact, %{
              metadata: metadata
            })

          {:ok, %{state | messages: new_messages, budget: new_budget}}

        :skip ->
          {:ok, state}

        {:error, _} = err ->
          err
      end
    else
      {:ok, state}
    end
  end

  defp compactor_module(%State{meta: meta}) do
    Map.get(meta, :compactor) ||
      Application.get_env(:ex_athena, :compactor_module) ||
      ExAthena.Compactor.Pipeline
  end

  # The system prompt is part of every request (it carries tool descriptions
  # and the skill catalog), so the compaction estimate must include it.
  defp system_prompt(%State{request_template: %{system_prompt: sp}}), do: sp
  defp system_prompt(_), do: nil

  defp set_finish_reason(%State{} = state, reason) do
    put_in(state.meta[:finish_reason], reason)
  end

  # ── PreIteration hook ─────────────────────────────────────────────

  defp run_pre_iteration_hook(%State{} = state) do
    payload = %{
      iteration: state.iterations,
      unproductive_iterations: state.unproductive_iterations,
      fingerprint: state.last_tool_fingerprint || [],
      session_id: state.session_id
    }

    case ExAthena.Hooks.run_lifecycle_with_outputs(state.hooks, :PreIteration, payload) do
      %{halt: {:halt, reason}} -> {:halt, reason}
      %{injects: [_ | _] = msgs} -> {:ok, %{state | messages: state.messages ++ msgs}}
      _ -> {:ok, state}
    end
  end

  # ── No-progress tracking ──────────────────────────────────────────

  defp update_progress_tracking(prev_state, new_state) do
    current_fp = compute_tool_fingerprint(prev_state, new_state)
    productive? = check_productivity(prev_state, new_state, current_fp)

    if productive? do
      %{new_state | unproductive_iterations: 0, last_tool_fingerprint: current_fp}
    else
      %{
        new_state
        | unproductive_iterations: new_state.unproductive_iterations + 1,
          last_tool_fingerprint: current_fp
      }
    end
  end

  defp check_productivity(prev_state, new_state, current_fp) do
    if function_exported?(new_state.mode, :productivity_signal, 2) do
      new_state.mode.productivity_signal(prev_state, new_state)
    else
      default_productivity_signal(prev_state, new_state, current_fp)
    end
  end

  defp default_productivity_signal(prev_state, new_state, current_fp) do
    has_new_text? =
      new_state.messages
      |> Enum.drop(length(prev_state.messages))
      |> Enum.any?(fn
        %{role: :assistant, content: c} when is_binary(c) and byte_size(c) > 0 -> true
        _ -> false
      end)

    current_fp != prev_state.last_tool_fingerprint or has_new_text?
  end

  @doc false
  def compute_tool_fingerprint(prev_state, new_state) do
    new_msgs = Enum.drop(new_state.messages, length(prev_state.messages))

    calls =
      new_msgs
      |> Enum.flat_map(fn
        %{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
        _ -> []
      end)
      |> Enum.map(fn tc ->
        args_bin =
          cond do
            is_nil(tc.arguments) -> "{}"
            is_binary(tc.arguments) -> tc.arguments
            true -> Jason.encode!(tc.arguments)
          end

        {tc.name, args_bin}
      end)
      |> Enum.sort()

    # Fold in a hash of the turn's tool RESULTS: a legitimately repeated
    # call whose OUTPUT changes (re-running tests after an edit, polling a
    # build) is progress, not a stall — name+args alone killed those runs.
    results_hash =
      new_msgs
      |> Enum.flat_map(fn
        %{role: :tool, tool_results: trs} when is_list(trs) -> Enum.map(trs, & &1.content)
        _ -> []
      end)
      |> :erlang.phash2()

    {calls, results_hash}
  end

  # ── Result construction ───────────────────────────────────────────

  defp to_result({:error, _} = err, _), do: err

  defp to_result(%State{} = state, started_at) do
    raw_finish_reason = state.meta[:finish_reason] || :stop

    {finish_reason, deliverable, halted_reason} =
      case {raw_finish_reason, state.halted_reason} do
        {:error_halted, {:submitted, d}} -> {:submitted, d, nil}
        {reason, hr} -> {reason, nil, hr}
      end

    final_text = extract_final_text(state)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    result = %Result{
      text: final_text,
      messages: state.messages,
      finish_reason: finish_reason,
      halted_reason: halted_reason,
      error_diagnostic: state.meta[:error_diagnostic],
      deliverable: deliverable,
      iterations: state.iterations,
      tool_calls_made: state.tool_calls_made,
      usage: state.budget && state.budget.usage,
      cost_usd: state.budget && state.budget.cost_usd,
      duration_ms: duration_ms,
      model: state.request_template && state.request_template.model,
      provider: state.provider_mod,
      session_id: state.meta[:provider_session_id],
      conclusions: state.meta[:ledger] || [],
      todos: state.meta[:todos] || [],
      telemetry: %{},
      no_progress_snapshot: state.no_progress_snapshot
    }

    fire_terminal_hooks(state, result)

    if finish_reason == :submitted do
      Events.emit(state.on_event, {:submitted, deliverable})
    end

    Events.emit(state.on_event, {:done, result})

    {:ok, result}
  end

  # Stop (success) / StopFailure (error) fire before SessionEnd so any
  # cleanup hook attached to SessionEnd can read both. Halts in any of
  # these are recorded but don't override the already-set finish_reason
  # (we're past the loop body).
  defp fire_terminal_hooks(
         %State{hooks: hooks, session_id: sid, parent_session_id: psid},
         %Result{
           finish_reason: reason
         } = result
       ) do
    payload = %{
      session_id: sid,
      parent_session_id: psid,
      finish_reason: reason,
      result: result
    }

    if reason in [:stop, :submitted] do
      _ = ExAthena.Hooks.run_lifecycle(hooks, :Stop, payload)
    else
      _ = ExAthena.Hooks.run_lifecycle(hooks, :StopFailure, payload)
    end

    _ = ExAthena.Hooks.run_lifecycle(hooks, :SessionEnd, payload)
    :ok
  end

  defp extract_final_text(%State{messages: messages}) do
    # The last NON-BLANK assistant message's content is the final text.
    # Error terminations cut runs mid-flight on tool-call-only turns whose
    # text channel is whitespace after <think>-fence filtering — skipping
    # blanks hands callers the run's last real observation instead of "\n\n".
    # Errors with no non-blank assistant message leave text nil.
    messages
    |> Enum.reverse()
    |> Enum.find_value(nil, fn
      %{role: :assistant, content: c} when is_binary(c) ->
        if String.trim(c) == "", do: nil, else: c

      _ ->
        nil
    end)
  end

  # ── Initial state assembly ────────────────────────────────────────

  defp build_initial_state(prompt, opts) do
    # Capture the provider atom before pop_provider! converts it to a module,
    # so we can pass it (along with base_url / model / api_key) down to any
    # subagents this loop spawns via spawn_agent_opts in assigns.
    raw_provider =
      Keyword.get(opts, :provider) ||
        Application.get_env(:ex_athena, :default_provider)

    {provider_mod, opts} = Config.pop_provider!(opts)

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    phase = Keyword.get(opts, :phase, :default)
    allowed_roots = resolve_allowed_roots(opts, cwd)
    assigns = Keyword.get(opts, :assigns, %{})
    mode = opts |> Keyword.get(:mode, :react) |> Mode.resolve()
    session_id = Keyword.get(opts, :session_id) || generate_session_id()
    parent_session_id = Keyword.get(opts, :parent_session_id)

    tool_specs = opts |> Tools.resolve() |> normalize_tool_list()

    with :ok <- validate_tools(tool_specs) do
      capabilities =
        if function_exported?(provider_mod, :capabilities, 1) do
          provider_mod.capabilities(opts)
        else
          provider_mod.capabilities()
        end
        |> Map.merge(Keyword.get(opts, :capabilities, %{}))

      memory_messages = resolve_memory(cwd, opts)
      skills = resolve_skills(cwd, opts)

      conclusions? = Keyword.get(opts, :conclusions, true)

      request_template =
        prompt
        |> Request.new(opts)
        |> apply_skills_catalog(skills)
        |> apply_conclusion_contract(conclusions?)

      permissions_opts = %{
        phase: phase,
        allowed_tools: Keyword.get(opts, :allowed_tools),
        disallowed_tools: Keyword.get(opts, :disallowed_tools),
        # Tools the read-only :plan phase may run beyond the builtin
        # read-only set: specs that declared themselves read-only (module
        # `read_only?/0` / MCP readOnlyHint) plus any names the host passed
        # explicitly via `readonly_tools:`.
        readonly_tools:
          Keyword.get(opts, :readonly_tools, []) ++
            for(spec <- tool_specs, spec.read_only?, do: spec.name),
        can_use_tool: Keyword.get(opts, :can_use_tool)
      }

      hooks_table = Keyword.get(opts, :hooks, %{})

      # Tools that fire hooks (e.g. SpawnAgent for SubagentStart/Stop) read
      # them from ctx.assigns[:hooks]. Carrying them through the context
      # avoids tools needing direct access to Loop.State.
      #
      # spawn_agent_opts carries the parent's connection config so subagents
      # inherit provider / base_url / model without needing explicit opts.
      # Map.put_new keeps a grandparent's config when this loop is itself a
      # subagent and the parent already set spawn_agent_opts.
      inherited_provider_opts =
        raw_provider
        |> inherit_provider_opts(opts)
        |> inherit_tool_ui_forwarder(opts)

      # When a Coordinator observes this run, tee every host event to it
      # (attributed as :main) and wire the side channels subagents use for
      # per-agent attribution. The coordinator is observational only — all
      # traffic is cast, so its absence or death never affects the run.
      coordinator = Keyword.get(opts, :coordinator)
      on_event = opts |> Keyword.get(:on_event) |> tee_coordinator(coordinator)

      assigns =
        assigns
        |> Map.put_new(:hooks, hooks_table)
        |> Map.put_new(
          :tool_timeout_ms,
          Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms)
        )
        |> Map.put_new(:spawn_agent_opts, inherited_provider_opts)
        # THIS run's effective permission guardrails, read by SpawnAgent so a
        # child is never more privileged than its parent (issue #130): the
        # deny/allow lists and approval callback are clamped onto every
        # sub_opts. Map.put (not put_new) — when this loop is itself a
        # subagent, assigns arrive pre-populated with the PARENT's guardrails,
        # and grandchildren must clamp against THIS run's (already-clamped)
        # settings, not the stale copy.
        |> Map.put(:run_permissions, permissions_opts)
        # web_fetch SSRF opt-out: local/private hosts are refused by default
        # (regardless of confinement); hosts opt in per run. put_new keeps a
        # value the caller already placed in assigns.
        |> Map.put_new(:allow_local_hosts, Keyword.get(opts, :allow_local_hosts, false))
        # Tools that surface events to the host (SpawnAgent's
        # subagent_spawn/result boundary events) read the callback from the
        # tool context. put_new keeps a callback the caller (or a spawning
        # parent) already placed in assigns.
        |> maybe_put_new_on_event(on_event)
        |> wire_coordinator(coordinator)
        |> maybe_put_subagent_suffix(Keyword.get(opts, :subagent_prompt_suffix))

      if coordinator, do: ExAthena.Orchestrator.Coordinator.attach_run(coordinator, self())

      ctx =
        ExAthena.ToolContext.new(
          cwd: cwd,
          phase: phase,
          session_id: session_id,
          allowed_roots: allowed_roots,
          assigns: assigns
        )

      preloaded_skills =
        []
        |> Skills.preload(skills, Keyword.get(opts, :preload_skills, []))

      initial_messages =
        memory_messages ++ preloaded_skills ++ request_template.messages

      # UserPromptSubmit fires before the first iteration. Hooks can
      # `{:inject, msg}` to add context, `{:transform, new_prompt}` to
      # rewrite the user message, or `{:halt, reason}` to abort. Only
      # the most-recently-added user message (the prompt the caller
      # passed) is replaced when transformed.
      {initial_messages, ups_halt} =
        apply_user_prompt_submit(hooks_table, initial_messages, %{
          prompt: prompt,
          session_id: session_id,
          parent_session_id: parent_session_id
        })

      state = %State{
        messages: initial_messages,
        tool_specs: tool_specs,
        capabilities: capabilities,
        provider_mod: provider_mod,
        provider_opts: Config.provider_opts(provider_mod, opts, raw_provider),
        request_template: request_template,
        permissions_opts: permissions_opts,
        hooks: Keyword.get(opts, :hooks, %{}) |> ImplicitDiagnostics.maybe_merge(),
        ctx: ctx,
        on_event: on_event,
        budget: Budget.new(),
        max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
        max_consecutive_mistakes:
          Keyword.get(opts, :max_consecutive_mistakes, @default_max_mistakes),
        max_unproductive_iterations:
          Keyword.get(opts, :max_unproductive_iterations, @default_max_unproductive_iterations),
        max_budget_usd: Keyword.get(opts, :max_budget_usd),
        tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms),
        max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
        mode: mode,
        mode_state: %{},
        session_id: session_id,
        parent_session_id: parent_session_id,
        meta:
          opts
          |> compaction_meta()
          |> Map.put(:skills, skills)
          |> Map.put(:memory_count, length(memory_messages))
          |> Map.put(:preloaded_skill_count, length(preloaded_skills))
          # Provider atom + queue opts for the per-call RequestQueue gate.
          # Modes wrap each provider call in RequestQueue.with_slot/3 so
          # concurrent loops (subagents!) serialize on scarce local GPU
          # slots. queue_timeout defaults to :infinity inside the loop —
          # the run's own timeout/budget guards bound total time, and a
          # queued subagent legitimately waits minutes for a slot.
          |> Map.put(:provider_atom, raw_provider)
          |> Map.put(:queue_opts,
            queue: Keyword.get(opts, :queue, true),
            timeout: Keyword.get(opts, :queue_timeout, :infinity)
          )
          # Per-iteration conclusions (see ExAthena.Conclusions): modes emit
          # {:conclusion, …} events and keep a rolling ledger here that is
          # recited back to the model at the request tail each turn.
          |> Map.put(:conclusions, conclusions?)
          # Opt-in micro-LLM distillation of thinking-blob conclusions
          # (see ReAct.maybe_summarize_conclusion).
          |> Map.put(:conclusion_summarizer, Keyword.get(opts, :conclusion_summarizer, false))
          |> Map.put(:ledger, [])
          # Whether the caller explicitly chose an iteration cap — modes that
          # default to :infinity (orchestrate) must honor an explicit choice.
          |> Map.put(:explicit_max_iterations?, Keyword.has_key?(opts, :max_iterations))
          |> maybe_put_halt(ups_halt)
      }

      _ =
        ExAthena.Hooks.run_lifecycle(state.hooks, :SessionStart, %{
          session_id: session_id,
          parent_session_id: parent_session_id
        })

      {:ok, state}
    end
  end

  defp maybe_put_new_on_event(assigns, nil), do: assigns
  defp maybe_put_new_on_event(assigns, on_event), do: Map.put_new(assigns, :on_event, on_event)

  # ── Coordinator wiring (see ExAthena.Orchestrator.Coordinator) ─────

  defp tee_coordinator(on_event, nil), do: on_event

  defp tee_coordinator(on_event, coordinator) do
    fn event ->
      ExAthena.Orchestrator.Coordinator.notify(coordinator, :main, event)
      if is_function(on_event, 1), do: on_event.(event)
      :ok
    end
  end

  defp wire_coordinator(assigns, nil), do: assigns

  defp wire_coordinator(assigns, coordinator) do
    existing_todo_writer = assigns[:todo_writer]

    todo_writer = fn todos ->
      ExAthena.Orchestrator.Coordinator.notify(coordinator, :main, {:todos, todos})
      if is_function(existing_todo_writer, 1), do: existing_todo_writer.(todos)
      :ok
    end

    # SpawnAgent tags each subagent's events with its generated id through
    # this sink so the coordinator can attribute them per agent.
    sink = fn sub_id, event ->
      ExAthena.Orchestrator.Coordinator.notify(coordinator, sub_id, event)
    end

    assigns
    |> Map.put(:todo_writer, todo_writer)
    |> Map.put(:agent_event_sink, sink)
  end

  defp maybe_put_subagent_suffix(assigns, nil), do: assigns

  defp maybe_put_subagent_suffix(assigns, suffix) when is_binary(suffix),
    do: Map.put_new(assigns, :subagent_prompt_suffix, suffix)

  # The CONCLUSION prompt contract (see ExAthena.Conclusions). Lenient by
  # design — the extraction has tail/derived fallbacks, so a model that
  # forgets the marker still produces a usable conclusion.
  @conclusion_contract """
  ## Conclusion protocol
  End EVERY reply — including replies that call tools — with a final line
  of exactly this form, as VISIBLE text OUTSIDE your thinking (after the
  </think> block, never inside it):
  CONCLUSION: <one sentence stating what you LEARNED or decided this turn>
  State findings ("X uses YAML frontmatter", "no blog directory exists"),
  not intentions ("let me check X").
  """

  defp apply_conclusion_contract(request, false), do: request

  defp apply_conclusion_contract(request, true) do
    contract = String.trim(@conclusion_contract)

    system_prompt =
      case request.system_prompt do
        nil -> contract
        "" -> contract
        existing -> existing <> "\n\n" <> contract
      end

    %{request | system_prompt: system_prompt}
  end

  defp apply_user_prompt_submit(hooks, messages, payload) do
    outputs = ExAthena.Hooks.run_lifecycle_with_outputs(hooks, :UserPromptSubmit, payload)

    new_messages =
      messages
      |> apply_transform(outputs.transform)
      |> Kernel.++(outputs.injects)

    {new_messages, outputs.halt}
  end

  # Replace the last user-role message's content with the transformed prompt.
  # If there's no user message in the list (system-prompt-only opening), we
  # append the transformed prompt as a user message.
  defp apply_transform(messages, nil), do: messages

  defp apply_transform(messages, prompt) when is_binary(prompt) do
    case last_user_index(messages) do
      nil ->
        messages ++ [ExAthena.Messages.user(prompt)]

      idx ->
        List.update_at(messages, idx, fn msg -> %{msg | content: prompt} end)
    end
  end

  defp last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%{role: :user}, idx} -> idx
      _ -> nil
    end)
  end

  defp maybe_put_halt(meta, nil), do: meta
  defp maybe_put_halt(meta, {:halt, reason}), do: Map.put(meta, :early_halt, reason)

  defp generate_session_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  # Confinement roots for this run (nil = unconfined, the default). `:allowed_roots`
  # takes an explicit list (cwd is always added); `confine: true` is shorthand for
  # `[cwd]`. Roots are expanded to absolute, deduped, and cwd-anchored so every
  # confined run can at least reach its own working directory.
  defp resolve_allowed_roots(opts, cwd) do
    cond do
      roots = Keyword.get(opts, :allowed_roots) ->
        [cwd | List.wrap(roots)]
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()

      Keyword.get(opts, :confine, false) ->
        [Path.expand(cwd)]

      true ->
        nil
    end
  end

  # Build the keyword list stored in assigns[:spawn_agent_opts] so subagents
  # launched by spawn_agent inherit the parent's connection settings.
  defp inherit_provider_opts(provider, opts) do
    [provider: provider]
    |> put_inherited(:base_url, opts)
    |> put_inherited(:model, opts)
    |> put_inherited(:api_key, opts)
    |> put_inherited(:permission_mode, opts)
    |> put_inherited(:conclusion_summarizer, opts)
  end

  # Forward :tool_ui events from subagents up to the parent's on_event so the
  # diff panel sees edits made inside spawn_agent. All other event kinds are
  # filtered out to avoid polluting the parent's chat stream with subagent
  # content/tool_call/tool_result events.
  defp inherit_tool_ui_forwarder(acc, opts) do
    case Keyword.fetch(opts, :on_event) do
      {:ok, parent_on_event} when is_function(parent_on_event, 1) ->
        forwarder = fn
          {:tool_ui, _} = event -> parent_on_event.(event)
          _ -> :ok
        end

        Keyword.put(acc, :on_event, forwarder)

      _ ->
        acc
    end
  end

  defp put_inherited(acc, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> Keyword.put(acc, key, val)
      :error -> acc
    end
  end

  # ── Memory + skills resolution ────────────────────────────────────

  defp resolve_memory(_cwd, opts) do
    case Keyword.get(opts, :memory, :auto) do
      false -> []
      :auto -> Memory.discover(opts |> Keyword.get(:cwd) || File.cwd!())
      list when is_list(list) -> list
    end
  end

  defp resolve_skills(_cwd, opts) do
    case Keyword.get(opts, :skills, :auto) do
      false -> %{}
      :auto -> Skills.discover(opts |> Keyword.get(:cwd) || File.cwd!())
      map when is_map(map) -> map
    end
  end

  defp apply_skills_catalog(%Request{} = request, skills) when map_size(skills) == 0,
    do: request

  defp apply_skills_catalog(%Request{system_prompt: sp} = request, skills) do
    catalog = Skills.catalog_section(skills)

    new_sp =
      case {sp, catalog} do
        {_, ""} -> sp
        {nil, c} -> c
        {prefix, c} -> prefix <> "\n\n" <> c
      end

    %{request | system_prompt: new_sp}
  end

  defp normalize_tool_list(specs) when is_list(specs), do: specs

  defp validate_tools(tool_modules) do
    try do
      Tools.validate!(tool_modules)
      :ok
    rescue
      e in ArgumentError ->
        {:error, Error.new(:bad_request, Exception.message(e), provider: :loop)}
    end
  end

  defp compaction_meta(opts) do
    [
      :compactor,
      :compact_at,
      :pinned_prefix_count,
      :live_suffix_count,
      :conversation_id,
      :agent_id,
      :reactive_compact,
      :auto_pin
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end
end
