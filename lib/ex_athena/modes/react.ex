defmodule ExAthena.Modes.ReAct do
  @moduledoc """
  Default mode: Reason-Act cycle.

  Each iteration:

    1. Build a Request from current messages + tools + system prompt.
    2. Call the provider — uses `stream/3` when the loop was started with
       `on_event:` set, translating provider `%Streaming.Event{}` deltas
       into Loop tuples (`{:content, chunk}`, `{:thinking, chunk}`) so
       they reach the caller in real time; falls back to one-shot
       `query/2` when no event callback is registered. When deltas
       streamed, the end-of-turn full-text emission is suppressed.
    3. Extract tool calls (native, or TextTagged fallback via
       `ExAthena.ToolCalls`).
    4. If no tool calls: emit `{:content, text}`, set `finish_reason:
       :stop`, and halt.
    5. If tool calls: run them (parallel-safe ones concurrently, mutating
       ones serially), append results, continue.

  Budget + mistake-counter checks happen between iterations in the kernel.
  This mode only implements the turn-by-turn behaviour.
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.{Budget, Messages, Permissions, Skills, Telemetry}
  alias ExAthena.Loop.{Events, Parallel, State}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Tools

  @impl true
  def init(%State{} = state), do: {:ok, state}

  @impl true
  def productivity_signal(prev_state, new_state) do
    current_fp = ExAthena.Loop.compute_tool_fingerprint(prev_state, new_state)

    # Text only counts as progress when it is non-blank AND differs from the
    # previous assistant turn — local reasoning models often emit a bare " "
    # or repeat the same sentence while re-issuing identical tool calls,
    # which must not reset the no-progress guard.
    prev_text = last_assistant_text(prev_state.messages)

    has_new_text? =
      new_state.messages
      |> Enum.drop(length(prev_state.messages))
      |> Enum.any?(fn
        %{role: :assistant, content: c} when is_binary(c) ->
          trimmed = String.trim(c)
          trimmed != "" and trimmed != prev_text

        _ ->
          false
      end)

    current_fp != prev_state.last_tool_fingerprint or has_new_text?
  end

  defp last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :assistant, content: c} when is_binary(c) -> String.trim(c)
      _ -> nil
    end)
  end

  @impl true
  def iterate(%State{} = state) do
    request = build_request(state)

    # ChatParams hooks fire just before the provider call so callers can
    # adjust temperature / tools / system_prompt per turn without
    # subclassing the mode. `{:inject, msg}` returns appended to the
    # request's messages; `{:halt, _}` short-circuits.
    case apply_chat_params(state, request) do
      {:halt, reason} ->
        state =
          %{state | halted_reason: reason}
          |> set_finish_reason(:error_halted)

        {:halt, state}

      {:ok, request, state} ->
        do_iterate(state, request)
    end
  end

  defp do_iterate(%State{} = state, request) do
    chat_meta =
      Telemetry.genai_meta(
        operation: "chat",
        provider: state.provider_mod,
        request_model: request.model,
        conversation_id: Map.get(state.meta, :conversation_id)
      )

    {stream_cb, counters} = stream_callback(state)

    case Telemetry.span([:ex_athena, :chat], chat_meta, fn ->
           query_or_stream(state, request, stream_cb)
         end) do
      {:ok, response} ->
        # Accumulate usage + cost before considering termination.
        state = fold_usage(state, response)
        # A successful call re-arms the transient-error retry budget.
        state = put_in(state.meta[:retried_transient?], false)

        # Providers with server-side conversation state (e.g. the Claude Code
        # CLI) report a session id; keep the latest so the Result can surface
        # it for hosts to pass back as `resume:`.
        state = stash_session_id(state, response)

        # When deltas already streamed to the host this turn, suppress the
        # end-of-turn full-text/full-thinking emission to avoid duplicates.
        # Counter-based (not static) because providers may export stream/3
        # yet emit zero deltas — those still need the final emission.
        streamed_text? = counters != nil and :counters.get(counters, 1) > 0
        streamed_thinking? = counters != nil and :counters.get(counters, 2) > 0

        case ExAthena.ToolCalls.extract(
               %{tool_calls: response.tool_calls, text: response.text},
               state.capabilities
             ) do
          {:ok, []} ->
            # Terminal: model returned plain text with no tool calls.
            unless streamed_thinking?, do: maybe_emit_thinking(state.on_event, response)
            unless streamed_text?, do: maybe_emit_content(state.on_event, response)

            state = record_conclusion(state, response, [])

            state =
              %{
                state
                | messages: state.messages ++ [Messages.assistant(response.text)]
              }
              |> set_finish_reason(:stop)

            {:halt, state}

          {:ok, tool_calls} ->
            unless streamed_thinking?, do: maybe_emit_thinking(state.on_event, response)
            unless streamed_text?, do: maybe_emit_content(state.on_event, response)

            state = record_conclusion(state, response, tool_calls)

            # Reasoning rides on the message (verbatim) so providers can
            # replay it within the current tool loop — dropping it between
            # tool calls measurably degrades multi-step tool use on
            # reasoning models (MiniMax ablation: −36% τ²-bench).
            assistant_msg = Messages.assistant(response.text, tool_calls, response.thinking)
            state = %{state | messages: state.messages ++ [assistant_msg]}

            runner = fn call, st -> run_single_tool_call(call, st) end
            mistakes_before = state.consecutive_mistakes

            case Parallel.run(tool_calls, state, runner) do
              {:ok, tool_messages, state} ->
                # Mistakes count at most ONCE per turn — a single turn with
                # 3 hallucinated calls used to terminate the run before the
                # model ever saw the redirect errors (turn-boundary
                # counting; the guard measures consecutive BAD TURNS).
                state = %{
                  state
                  | consecutive_mistakes: min(state.consecutive_mistakes, mistakes_before + 1),
                    messages: state.messages ++ tool_messages,
                    tool_calls_made: state.tool_calls_made + length(tool_calls)
                }

                # Track the run's latest successful todo list (like the
                # conclusions ledger) — exposed on Result.todos so failed
                # workers can hand back Completed/Remaining.
                state = record_todos(state, tool_calls, tool_messages)

                # Turn-boundary reset on any success — see ADR adr-1-reset-consecutive-mistakes-at-turn-boundary.md.
                state =
                  if any_tool_success?(tool_messages),
                    do: reset_mistakes(state),
                    else: state

                state = maybe_attach_skills(state, response.text)

                {:continue, state}

              {:halt, reason, state} ->
                state =
                  %{state | halted_reason: reason}
                  |> set_finish_reason(:error_halted)

                {:halt, state}
            end

          {:error, reason} ->
            diagnostic = %{
              schema: request.response_format,
              received: response.text,
              violations: [%{reason: inspect(reason)}]
            }

            state = %{state | halted_reason: {:tool_call_parse_failed, reason}}
            state = put_in(state.meta[:error_diagnostic], diagnostic)
            state = set_finish_reason(state, :error_schema_validation)

            {:halt, state}
        end

      {:error, %ExAthena.Error{kind: :unauthorized} = reason} ->
        state =
          %{state | halted_reason: reason}
          |> set_finish_reason(:error_provider_auth)

        {:halt, state}

      # The prompt exceeded the model's context window (req_llm maps an HTTP
      # 413 to `:context_length_exceeded`). Surface the kernel's typed
      # capacity signal so it force-compacts the existing context and retries
      # this iteration once, rather than dying as a generic execution error.
      {:error, %ExAthena.Error{kind: :context_length_exceeded}} ->
        {:error, :error_prompt_too_long}

      {:error, reason} ->
        # One bounded retry for TRANSIENT provider failures — a single exo
        # hiccup / transport blip used to kill whole runs (Req doesn't
        # retry POSTs). Anything else, or a second failure, halts.
        # `!= true` (not `not …`) because :retried_transient? is unset (nil) on
        # the first transient error — `not nil` raises ArgumentError.
        if transient_error?(reason) and state.meta[:retried_transient?] != true do
          state = put_in(state.meta[:retried_transient?], true)
          Process.sleep(2_000)
          do_iterate(state, request)
        else
          state =
            %{state | halted_reason: reason}
            |> set_finish_reason(:error_during_execution)

          {:halt, state}
        end
    end
  end

  defp transient_error?(%ExAthena.Error{kind: kind}),
    do: kind in [:server_error, :timeout, :transport, :rate_limited]

  defp transient_error?(:timeout), do: true
  defp transient_error?(_), do: false

  # Fire ChatParams hooks. Returns {:ok, request, state} (possibly with
  # injected messages appended) or {:halt, reason} when a hook bailed.
  defp apply_chat_params(state, request) do
    payload = %{
      request: request,
      session_id: state.session_id,
      messages: request.messages
    }

    outputs = ExAthena.Hooks.run_lifecycle_with_outputs(state.hooks, :ChatParams, payload)

    case outputs.halt do
      {:halt, reason} ->
        {:halt, reason}

      _ ->
        request_with_injects =
          case outputs.injects do
            [] -> request
            list -> %{request | messages: request.messages ++ list}
          end

        state =
          case outputs.injects do
            [] -> state
            list -> %{state | messages: state.messages ++ list}
          end

        {:ok, request_with_injects, state}
    end
  end

  # ── Tool execution for one call ───────────────────────────────────

  defp run_single_tool_call(%ToolCall{} = call, state) do
    # Surface the call to the host BEFORE gating/execution so UIs can show a
    # "running…" state — matching the Claude Code provider, whose tool-call
    # events stream when the model requests the tool. The matching
    # {:tool_result, _} follows once the call is gated/executed.
    Events.emit(state.on_event, {:tool_call, call})

    case Parallel.pre_tool_gate(call, state) do
      :allow ->
        do_execute(call, state)

      {:deny, %Permissions.Denial{reason: reason_str}} ->
        result = Messages.tool_result(call.id, reason_str, true)
        state = bump_mistake(state)
        Parallel.emit_result_events(state, call, result)
        {result, state}

      {:deny, reason} ->
        result = Messages.tool_result(call.id, "permission denied: #{inspect(reason)}", true)
        state = bump_mistake(state)
        Parallel.emit_result_events(state, call, result)
        {result, state}

      {:halt, reason} ->
        {{:halt, reason}, state}
    end
  end

  # Parse-failure sentinel (Native.parse) — per-call repair error so the
  # model fixes its JSON instead of the batch (or run) dying.
  defp do_execute(%ToolCall{arguments: %{"__invalid_json__" => raw}} = call, state) do
    result =
      Messages.tool_result(
        call.id,
        "tool arguments were not valid JSON: #{raw}. " <>
          "Re-send the #{call.name} call with corrected JSON arguments.",
        true
      )

    state = bump_mistake(state)
    Parallel.emit_result_events(state, call, result)
    {result, state}
  end

  defp do_execute(%ToolCall{} = call, state) do
    ctx = %{state.ctx | tool_call_id: call.id}

    tool_meta =
      Telemetry.genai_meta(
        operation: "execute_tool",
        tool_name: call.name,
        tool_call_id: call.id,
        conversation_id: Map.get(state.meta, :conversation_id)
      )

    case Tools.find(state.tool_specs, call.name) do
      nil ->
        result = Messages.tool_result(call.id, unknown_tool_error(call.name, state), true)
        state = bump_mistake(state)
        Parallel.emit_result_events(state, call, result)
        {result, state}

      spec ->
        case safe_execute(tool_meta, spec, call, ctx) do
          {:ok, %{phase_transition: new_phase} = payload} when call.name == "plan_mode" ->
            # Phase transition sentinel — special-case only in the single-tool
            # runner, and ONLY for the plan_mode tool. Honouring the sentinel
            # from arbitrary tools would let any custom/MCP tool (including
            # ones marked read-only) smuggle a privilege escalation past the
            # permission gate; a non-plan_mode payload that happens to carry
            # the key falls through to the generic clause below and is merely
            # stringified. plan_mode itself is approval-gated in
            # `Permissions.check/3` before it ever executes.
            msg = Map.get(payload, :message, "phase -> #{new_phase}")
            state = %{state | ctx: %{state.ctx | phase: new_phase}}
            result = Messages.tool_result(call.id, to_string(msg))
            after_post_hook(state, call, result)

          {:ok, text, %{kind: kind, payload: payload}} ->
            # Tool returned the structured split — LLM-facing text plus a
            # UI payload hosts can render natively. The tool-result
            # message carries the text for the model; ui_payload tags it
            # for the next :tool_ui event.
            ui = %{kind: kind, payload: payload}
            result = Messages.tool_result(call.id, stringify(text), nil, ui)
            after_post_hook(state, call, result)

          {:ok, payload} ->
            result = Messages.tool_result(call.id, stringify(payload))
            after_post_hook(state, call, result)

          {:error, reason} ->
            result = Messages.tool_result(call.id, "error: #{stringify(reason)}", true)
            state = bump_mistake(state)
            # PostToolUseFailure fires only on tool error; PostToolUse
            # fires on success (in after_post_hook below). Both ignore
            # `:deny` returns since it's too late, but `:halt` is honoured.
            _ =
              ExAthena.Hooks.run_lifecycle(state.hooks, :PostToolUseFailure, %{
                tool_name: call.name,
                tool_use_id: call.id,
                reason: reason
              })

            after_post_hook(state, call, result)

          {:halt, reason} ->
            {{:halt, reason}, state}

          other ->
            result = Messages.tool_result(call.id, "invalid tool return: #{inspect(other)}", true)
            state = bump_mistake(state)
            after_post_hook(state, call, result)
        end
    end
  end

  # A raising tool in the SERIAL path used to crash the whole loop process
  # (parallel tasks were already isolated) — e.g. edit with
  # `"replace_all": "true"` (string) raising FunctionClauseError, a typical
  # small-model arg shape. Exceptions become per-call errors.
  defp safe_execute(tool_meta, spec, call, ctx) do
    Telemetry.span([:ex_athena, :tool], tool_meta, fn ->
      ExAthena.Tool.Spec.execute(spec, call.arguments, ctx)
    end)
  rescue
    e -> {:error, "tool crashed: #{Exception.message(e)}"}
  end

  # Run PostToolUse hooks then emit events.
  # The payload includes `arguments` and `cwd` so hooks like
  # ImplicitDiagnostics can resolve the affected file.
  defp after_post_hook(state, call, result) do
    payload = %{
      result: result,
      arguments: call.arguments,
      cwd: state.ctx.cwd,
      tool_name: call.name
    }

    case ExAthena.Hooks.run_post_tool_use(state.hooks, call.name, payload, call.id) do
      {:halt, reason} ->
        {{:halt, reason}, state}

      {:augment, extra} ->
        [tr | rest] = result.tool_results
        augmented_tr = %{tr | content: tr.content <> "\n\n" <> extra}
        augmented = %{result | tool_results: [augmented_tr | rest]}
        emit_and_return(state, call, augmented)

      _ ->
        emit_and_return(state, call, result)
    end
  end

  defp emit_and_return(state, call, result) do
    Parallel.emit_result_events(state, call, result)
    {result, state}
  end

  # ── State helpers ─────────────────────────────────────────────────

  defp bump_mistake(%State{consecutive_mistakes: n} = state),
    do: %{state | consecutive_mistakes: n + 1}

  defp reset_mistakes(state), do: %{state | consecutive_mistakes: 0}

  # True when at least one tool message in the batch carries a non-error result.
  # `is_error` is nil on success and true on failure; nil != true covers both.
  defp any_tool_success?(messages) do
    Enum.any?(messages, fn
      %{tool_results: [%{is_error: err} | _]} -> err != true
      _ -> false
    end)
  end

  defp set_finish_reason(state, reason) do
    put_in(state.meta[:finish_reason], reason)
  end

  defp stash_session_id(state, %{session_id: sid}) when is_binary(sid) and sid != "",
    do: put_in(state.meta[:provider_session_id], sid)

  defp stash_session_id(state, _response), do: state

  defp fold_usage(state, response) do
    budget = state.budget || Budget.new()
    # Providers that report cost (req_llm via models.dev) include a
    # `:total_cost` key on usage. Fall back to nil when absent; the budget
    # accumulator treats nil as "no cost data this turn".
    cost = extract_cost(response.usage)
    new_budget = Budget.add(budget, response.usage, cost)

    if response.usage do
      Events.emit(state.on_event, {:usage, response.usage})
    end

    %{state | budget: new_budget}
  end

  # ── Conclusions (see ExAthena.Conclusions) ────────────────────────

  # Emit the per-iteration {:conclusion, …} event and fold it into the
  # rolling ledger (recited at the request tail next turn). Disabled via
  # `conclusions: false` on the run.
  @ledger_size 10

  # Latest SUCCESSFUL todo_write list → state.meta[:todos] (Result.todos).
  defp record_todos(state, tool_calls, tool_messages) do
    successful_ids =
      tool_messages
      |> Enum.flat_map(fn
        %{role: :tool, tool_results: trs} when is_list(trs) -> trs
        _ -> []
      end)
      |> Enum.reject(&(&1.is_error == true))
      |> MapSet.new(& &1.tool_call_id)

    tool_calls
    |> Enum.filter(&(&1.name == "todo_write" and MapSet.member?(successful_ids, &1.id)))
    |> List.last()
    |> case do
      nil -> state
      tc -> %{state | meta: Map.put(state.meta, :todos, List.wrap(tc.arguments["todos"]))}
    end
  end

  defp record_conclusion(%State{meta: %{conclusions: false}} = state, _response, _calls),
    do: state

  defp record_conclusion(state, response, tool_calls) do
    case ExAthena.Conclusions.from_turn(
           response.text,
           response.thinking,
           Enum.map(tool_calls, & &1.name)
         ) do
      {:ok, %{text: text, source: source}} ->
        {text, source} = maybe_summarize_conclusion(state, text, source)
        entry = %{iteration: state.iterations, text: text, source: source}
        Events.emit(state.on_event, {:conclusion, entry})

        ledger = Enum.take((state.meta[:ledger] || []) ++ [entry], -@ledger_size)
        put_in(state.meta[:ledger], ledger)

      :none ->
        state
    end
  end

  # Optional (opt-in, `conclusion_summarizer: true`): distill a raw
  # thinking-blob conclusion into ONE finding sentence via a tool-less
  # micro-call through the GPU queue. Success upgrades the entry to
  # :stated (it IS a real conclusion now — persists in recitation);
  # any failure keeps the raw blob.
  defp maybe_summarize_conclusion(
         %State{meta: %{conclusion_summarizer: true}} = state,
         blob,
         :thinking
       ) do
    request = %ExAthena.Request{
      messages: [
        Messages.user(
          # `/no_think` disables reasoning (Qwen soft switch) — without it a
          # thinking model burns the whole budget inside <think> and returns
          # a one-word fragment ("ize", "learned"). Budget still covers a
          # stray think block on models that ignore the switch.
          "/no_think\nSummarize this reasoning into ONE sentence stating what was learned or " <>
            "decided (a finding, not an intention). Reply with ONLY the sentence:\n\n" <> blob
        )
      ],
      model: state.request_template && state.request_template.model,
      max_tokens: 256,
      temperature: 0.2,
      timeout_ms: 60_000
    }

    result =
      ExAthena.RequestQueue.with_slot(
        state.meta[:provider_atom],
        fn -> state.provider_mod.query(request, state.provider_opts) end,
        state.meta[:queue_opts] || []
      )

    case result do
      {:ok, %{text: summary}} when is_binary(summary) ->
        s = String.trim(summary)
        # Quality gate: a thinking model that ignored /no_think returns a
        # one-word fragment ("Services", "intention") — WORSE than the raw
        # blob. Keep the summary only when it reads like a sentence;
        # otherwise fall back to the (readable) thinking blob.
        if sentence_like?(s), do: {s, :stated}, else: {blob, :thinking}

      _ ->
        {blob, :thinking}
    end
  rescue
    _ -> {blob, :thinking}
  end

  defp maybe_summarize_conclusion(_state, text, source), do: {text, source}

  defp sentence_like?(s) do
    String.length(s) >= 15 and length(String.split(s, ~r/\s+/, trim: true)) >= 3
  end

  # Manus-style recitation: replay the rolling conclusions ledger as an
  # EPHEMERAL message at the request tail — never persisted into
  # state.messages, so the transcript prefix stays append-only (KV-cache
  # friendly) and the reminder always sits in the model's most recent
  # attention span.
  defp recitation(%State{meta: %{conclusions: false}}), do: []
  defp recitation(%State{meta: %{ledger: []}}), do: []

  defp recitation(%State{meta: %{ledger: [_ | _] = ledger}} = state) do
    # The PREVIOUS turn's conclusion is already the most recent assistant
    # message in context — reciting it back invites recency-bias parroting
    # (a stale "waiting for user input" conclusion made the model claim it
    # was still waiting AFTER the answer arrived). Recite only the older
    # entries; the stall directive still considers the full ledger.
    last_iter = List.last(ledger).iteration

    older =
      ledger
      |> Enum.drop(-1)
      # Stale REASONING is a re-execution hazard: old "Let me check X…"
      # intents recited back can anchor the model into redoing completed
      # actions. Thinking-sourced entries age out after 3 iterations;
      # stated/tail findings persist (they're distilled facts).
      |> Enum.reject(fn e -> e.source == :thinking and last_iter - e.iteration > 3 end)

    case older do
      [] ->
        []

      older ->
        # Whole thinking blobs live in the UI/failure digests; the per-turn
        # recitation carries a ~200-char excerpt (full blobs would prefill
        # ~2k extra tokens EVERY turn on a 1-slot GPU).
        lines =
          Enum.map_join(older, "\n", fn e ->
            "- (iteration #{e.iteration}) #{recitation_text(e)}"
          end)

        [
          Messages.user("""
          [progress ledger — runtime-generated reminder, not a user message]
          Conclusions so far:
          #{lines}
          #{ledger_directive(state, ledger)}\
          """)
        ]
    end
  end

  defp recitation(_state), do: []

  defp recitation_text(%{source: :thinking, text: text}) do
    if String.length(text) > 200, do: String.slice(text, 0, 200) <> "…", else: text
  end

  defp recitation_text(%{text: text}), do: text

  # Magentic-One-style outer-loop response to a stall: when the last
  # conclusions are identical the agent is spinning — escalate the reminder
  # into a corrective instruction. Identical DERIVED texts ("ran bash") are
  # weak evidence — a busy worker yields them every turn while each call
  # differs — so those only escalate when the kernel's tool fingerprint
  # also says the turns were unproductive.
  defp ledger_directive(state, ledger) do
    # When the repetition is itself a research signal, the research note (which
    # rides earlier in the same request tail) carries the steer — don't ALSO
    # tell the model to "change strategy", or it gets contradictory nudges.
    if ledger_repeated?(state, ledger) and not needs_research?(state) do
      """
      You are repeating yourself without making progress — change strategy NOW:
      stop exploratory commands, record/update your todo list (todo_write),
      and act on the next pending item (delegate it with spawn_agent if available).
      """
    else
      "Stay focused on the remaining work; do not repeat completed steps."
    end
  end

  # Shared with the research rail (needs_research?/1). Identical DERIVED texts
  # ("ran bash") are weak evidence — only a stall when the kernel's fingerprint
  # also says the turns were unproductive.
  defp ledger_repeated?(state, ledger) do
    case Enum.take(ledger, -2) do
      [%{text: same, source: s1}, %{text: same, source: s2}] ->
        if s1 == :derived and s2 == :derived,
          do: state.unproductive_iterations > 0,
          else: true

      _ ->
        false
    end
  end

  # ── Research rail ─────────────────────────────────────────────────
  #
  # Deterministic "go online when local context runs out". When a planning/
  # investigation turn shows it lacks context — an empty/failed local search,
  # a recorded negative finding, or repetition — steer the model to web_search
  # (then web_fetch) instead of re-running the same local lookups. Pairs with
  # the prompt steering in the agent defs / mode addenda.

  @research_local_tools ~w(grep glob read web_fetch)
  @max_research_searches 2
  @empty_result_re ~r/no matches|no files found|0 results|no results|not found/i

  # Ephemeral request-tail directive (cache-safe — never persisted). Only emitted
  # when a signal fires AND the over-search cap allows AND web_search is actually
  # in scope for this agent.
  defp research_note(state) do
    if needs_research?(state) do
      [
        Messages.user(
          "[runtime] Local context looks insufficient (a search/fetch came up empty, you " <>
            "recorded a negative finding, or you are repeating yourself). Before continuing, " <>
            "call web_search with a focused query to find authoritative external information, " <>
            "then web_fetch the most relevant result. Do NOT re-run the same local glob/grep."
        )
      ]
    else
      []
    end
  end

  defp needs_research?(state) do
    web_search_available?(state) and research_budget_left?(state) and
      (empty_local_result?(state) or negative_finding_signal?(state) or
         ledger_repeated_signal?(state))
  end

  defp web_search_available?(%State{tool_specs: specs}),
    do: Enum.any?(specs, &(&1.name == "web_search"))

  # Over-search guard, derived purely from the transcript: once the agent has
  # already issued @max_research_searches web_search calls, stop nudging.
  defp research_budget_left?(%State{messages: messages}),
    do: count_tool_calls(messages, "web_search") < @max_research_searches

  # Signal A — the most recent tool turn's results include an empty/failed
  # local-context lookup (grep/glob/read/web_fetch).
  defp empty_local_result?(state) do
    state
    |> last_tool_results_with_names()
    |> Enum.any?(fn
      {name, %{is_error: err, content: content}} ->
        name in @research_local_tools and (err == true or empty_content?(content))

      _ ->
        false
    end)
  end

  defp empty_content?(content) do
    text = to_string(content)
    String.trim(text) == "" or Regex.match?(@empty_result_re, text)
  end

  # Signal B — the latest recorded conclusion is a negative finding.
  defp negative_finding_signal?(%State{meta: %{ledger: [_ | _] = ledger}}),
    do: ExAthena.Conclusions.negative_finding?(List.last(ledger).text)

  defp negative_finding_signal?(_state), do: false

  # Signal C — the ledger is repeating (shared with ledger_directive).
  defp ledger_repeated_signal?(%State{meta: %{ledger: [_ | _] = ledger}} = state),
    do: ledger_repeated?(state, ledger)

  defp ledger_repeated_signal?(_state), do: false

  defp last_tool_results_with_names(%State{messages: messages}) do
    name_by_id =
      messages
      |> Enum.flat_map(fn
        %Messages.Message{role: :assistant, tool_calls: tcs} when is_list(tcs) -> tcs
        _ -> []
      end)
      |> Map.new(fn tc -> {tc.id, tc.name} end)

    case Enum.find(Enum.reverse(messages), &match?(%Messages.Message{role: :tool}, &1)) do
      %Messages.Message{tool_results: results} when is_list(results) ->
        Enum.map(results, fn r -> {name_by_id[r.tool_call_id], r} end)

      _ ->
        []
    end
  end

  defp count_tool_calls(messages, name) do
    messages
    |> Enum.flat_map(fn
      %Messages.Message{role: :assistant, tool_calls: tcs} when is_list(tcs) -> tcs
      _ -> []
    end)
    |> Enum.count(&(&1.name == name))
  end

  # ── Request building ──────────────────────────────────────────────

  defp build_request(state) do
    %{
      state.request_template
      | messages:
          state.messages ++
            phase_note(state) ++ budget_note(state) ++ research_note(state) ++ recitation(state),
        tools: tool_schemas(state.tool_specs, state.capabilities),
        system_prompt: effective_system_prompt(state)
    }
  end

  # Turn-budget wrap-up pressure (cache-safe tail): a finite-cap loop that
  # keeps gathering will exhaust its budget mid-exploration and get cut off
  # before writing its report (observed: explore workers read until the
  # 25-turn cap, returning incomplete findings). Once it enters the final
  # stretch, push it to stop and produce its answer.
  defp budget_note(%State{max_iterations: max, iterations: i}) when is_integer(max) and max > 0 do
    remaining = max - i

    if remaining <= max(3, div(max, 4)) do
      [
        Messages.user(
          "[runtime] You have #{max(remaining, 1)} of #{max} turns left — wrap up NOW: " <>
            "STOP gathering and produce your final answer/report with what you already have. " <>
            "Do not start new exploration."
        )
      ]
    else
      []
    end
  end

  defp budget_note(_state), do: []

  # Mode-supplied EPHEMERAL phase steering at the request tail (cache-safe:
  # the system prompt and transcript prefix stay byte-stable; only the tail
  # varies). Never persisted into state.messages.
  defp phase_note(%State{meta: %{phase_note: note}}) when is_binary(note) and note != "",
    do: [Messages.user(note)]

  defp phase_note(_state), do: []

  defp tool_schemas(modules, %{native_tool_calls: true} = caps),
    do: Tools.describe_for_provider(modules, compact: caps[:compact_tool_schemas] == true)

  defp tool_schemas(_modules, _caps), do: nil

  defp effective_system_prompt(%State{capabilities: %{native_tool_calls: true}} = state),
    do: state.request_template.system_prompt

  # Self-contained agents (Claude Code CLI) own their tool loop — never inject
  # the text-tagged protocol, or they roleplay both sides and echo fences.
  defp effective_system_prompt(%State{capabilities: %{self_contained_tools: true}} = state),
    do: state.request_template.system_prompt

  defp effective_system_prompt(state) do
    ExAthena.ToolCalls.augment_system_prompt(
      state.request_template.system_prompt,
      Tools.describe_for_prompt(state.tool_specs)
    )
  end

  # ── Provider dispatch: query vs stream ────────────────────────────

  # When the caller registered `on_event` and the provider supports
  # streaming, build a translating callback (provider `%Streaming.Event{}`
  # structs → Loop tuples like `{:content, chunk}`) plus a counters ref
  # tracking how many text/thinking deltas were forwarded, so do_iterate
  # can suppress the duplicate end-of-turn emission. Returns {nil, nil}
  # when streaming doesn't apply, which routes to one-shot `query/2`.
  #
  # Native-tool-call providers get execution-time {:tool_call} events from
  # the loop itself; non-native ones (e.g. claude_code with CLI-internal
  # tools) have no other source, so forward stream-level tool events. The
  # same non-native providers speak the TextTagged protocol — their tool
  # calls arrive as `~~~tool_call` fences inside the text deltas — so also
  # filter those fences out of the visible {:content, _} stream (the loop
  # surfaces the parsed calls as {:tool_call, _} events when it runs them).
  # Public (but undocumented) so the planning phases of other modes
  # (Orchestrate, PlanAndSolve) can stream their single inference turn with
  # the same translation/suppression semantics as ReAct turns.
  @doc false
  def stream_callback(%State{on_event: on_event} = state)
      when is_function(on_event, 1) do
    if function_exported?(state.provider_mod, :stream, 3) do
      non_native = not (state.capabilities[:native_tool_calls] || false)

      Events.provider_stream_callback(on_event,
        forward_tool_events: non_native,
        filter_tool_fences: non_native
      )
    else
      {nil, nil}
    end
  end

  def stream_callback(_state), do: {nil, nil}

  # Every provider call goes through the request queue (per-call granularity)
  # so concurrent loops — especially subagents — serialize on the provider's
  # scarce slots (local GPUs serve 1-3 concurrent requests). The slot is held
  # for the full call/stream lifetime and released on every exit path; the
  # provider's own timeout_ms only starts once the slot is acquired.
  defp query_or_stream(state, request, stream_cb) do
    ExAthena.RequestQueue.with_slot(
      state.meta[:provider_atom],
      fn -> provider_call(state, request, stream_cb) end,
      Keyword.merge(
        state.meta[:queue_opts] || [],
        on_wait: Events.queue_wait_emitter(state.on_event, state.meta[:provider_atom])
      )
    )
  end

  defp provider_call(state, request, nil),
    do: state.provider_mod.query(request, state.provider_opts)

  defp provider_call(state, request, stream_cb),
    do: state.provider_mod.stream(request, stream_cb, state.provider_opts)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value, pretty: true, limit: :infinity)

  # A bare "unknown tool" gives small models nothing to act on — when the
  # name is a real builtin that just isn't in THIS loop's toolset (e.g. an
  # orchestrator hallucinating `read`), redirect to delegation instead of
  # letting it retry into the mistake cap.
  defp unknown_tool_error(name, state) do
    known_builtin? = Enum.any?(ExAthena.Tools.builtins(), &(&1.name() == name))
    can_delegate? = Tools.find(state.tool_specs, "spawn_agent") != nil

    cond do
      known_builtin? and can_delegate? ->
        "tool '#{name}' is not available to you — delegate this step to a worker " <>
          "via spawn_agent instead (workers have the full toolset)."

      known_builtin? ->
        "tool '#{name}' is not available in this phase."

      true ->
        "unknown tool: #{name}"
    end
  end

  # ── Skill auto-load via [skill: name] sentinel ────────────────────

  # When the model emits `[skill: name]` in its response text, append the
  # skill body to the conversation so it's visible on the next iteration.
  # Idempotent (already-loaded skills are no-ops). Unknown skill names
  # are silently ignored — the catalog already lists what's available.
  defp maybe_attach_skills(%State{} = state, nil), do: state
  defp maybe_attach_skills(%State{} = state, ""), do: state

  defp maybe_attach_skills(%State{meta: meta} = state, text) when is_binary(text) do
    skills = Map.get(meta, :skills, %{})

    case Skills.extract_sentinels(text) do
      [] ->
        state

      names ->
        already = Skills.loaded_skills(state.messages)

        extras =
          names
          |> Enum.reject(&MapSet.member?(already, &1))
          |> Enum.flat_map(fn name ->
            case Skills.activation_message(skills, name) do
              {:ok, msg} -> [msg]
              {:error, _} -> []
            end
          end)

        case extras do
          [] -> state
          msgs -> %{state | messages: state.messages ++ msgs}
        end
    end
  end

  # Emit a {:thinking, text} loop event when the provider surfaced any
  # reasoning content. Skipped silently when the response has no thinking
  # (most providers, simple models, or when thinking was disabled).
  defp maybe_emit_thinking(on_event, %{thinking: text})
       when is_binary(text) and text != "" do
    Events.emit(on_event, {:thinking, text})
  end

  defp maybe_emit_thinking(_on_event, _response), do: :ok

  # Emit the end-of-turn {:content, text} only when there is actual text.
  # Tool-call-only turns (common for native-tool-call models that narrate in
  # the thinking channel) have none — emitting {:content, ""} would render
  # an empty assistant block in host UIs.
  defp maybe_emit_content(on_event, %{text: text}) when is_binary(text) and text != "" do
    Events.emit(on_event, {:content, text})
  end

  defp maybe_emit_content(_on_event, _response), do: :ok

  defp extract_cost(nil), do: nil

  defp extract_cost(usage) when is_map(usage) do
    # req_llm uses :total_cost (in USD). Some providers may emit
    # input_cost/output_cost split with no total — sum them on the fly.
    cond do
      cost = Map.get(usage, :total_cost) ->
        cost

      cost = Map.get(usage, "total_cost") ->
        cost

      ic = Map.get(usage, :input_cost) || Map.get(usage, "input_cost") ->
        oc = Map.get(usage, :output_cost) || Map.get(usage, "output_cost") || 0
        ic + oc

      true ->
        nil
    end
  end

  defp extract_cost(_), do: nil
end
