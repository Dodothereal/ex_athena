defmodule ExAthena.Modes.ReAct do
  @moduledoc """
  Default mode: Reason-Act cycle.

  Each iteration:

    1. Build a Request from current messages + tools + system prompt.
    2. Call the provider — uses `stream/3` when the loop was started with
       `on_event:` set (so partial token deltas flow to the caller in
       real time), falls back to one-shot `query/2` when no event
       callback is registered.
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

    has_new_text? =
      new_state.messages
      |> Enum.drop(length(prev_state.messages))
      |> Enum.any?(fn
        %{role: :assistant, content: c} when is_binary(c) and byte_size(c) > 0 -> true
        _ -> false
      end)

    current_fp != prev_state.last_tool_fingerprint or has_new_text?
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

    case Telemetry.span([:ex_athena, :chat], chat_meta, fn ->
           query_or_stream(state, request)
         end) do
      {:ok, response} ->
        # Accumulate usage + cost before considering termination.
        state = fold_usage(state, response)

        case ExAthena.ToolCalls.extract(
               %{tool_calls: response.tool_calls, text: response.text},
               state.capabilities
             ) do
          {:ok, []} ->
            # Terminal: model returned plain text with no tool calls.
            maybe_emit_thinking(state.on_event, response)
            Events.emit(state.on_event, {:content, response.text || ""})

            state =
              %{
                state
                | messages: state.messages ++ [Messages.assistant(response.text)]
              }
              |> set_finish_reason(:stop)

            {:halt, state}

          {:ok, tool_calls} ->
            maybe_emit_thinking(state.on_event, response)
            Events.emit(state.on_event, {:content, response.text || ""})

            assistant_msg = Messages.assistant(response.text, tool_calls)
            state = %{state | messages: state.messages ++ [assistant_msg]}

            runner = fn call, st -> run_single_tool_call(call, st) end

            case Parallel.run(tool_calls, state, runner) do
              {:ok, tool_messages, state} ->
                state = %{
                  state
                  | messages: state.messages ++ tool_messages,
                    tool_calls_made: state.tool_calls_made + length(tool_calls)
                }

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
        state =
          %{state | halted_reason: reason}
          |> set_finish_reason(:error_during_execution)

        {:halt, state}
    end
  end

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
    case Parallel.pre_tool_gate(call, state) do
      :allow ->
        do_execute(call, state)

      {:deny, %Permissions.Denial{reason: reason_str}} ->
        result = Messages.tool_result(call.id, reason_str, true)
        state = bump_mistake(state)
        Parallel.emit_events(state, call, result)
        {result, state}

      {:deny, reason} ->
        result = Messages.tool_result(call.id, "permission denied: #{inspect(reason)}", true)
        state = bump_mistake(state)
        Parallel.emit_events(state, call, result)
        {result, state}

      {:halt, reason} ->
        {{:halt, reason}, state}
    end
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
        result = Messages.tool_result(call.id, "unknown tool: #{call.name}", true)
        state = bump_mistake(state)
        Parallel.emit_events(state, call, result)
        {result, state}

      spec ->
        case Telemetry.span([:ex_athena, :tool], tool_meta, fn ->
               ExAthena.Tool.Spec.execute(spec, call.arguments, ctx)
             end) do
          {:ok, %{phase_transition: new_phase} = payload} ->
            # Phase transition sentinel — special-case only in the single-tool runner.
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
    Parallel.emit_events(state, call, result)
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

  # ── Request building ──────────────────────────────────────────────

  defp build_request(state) do
    %{
      state.request_template
      | messages: state.messages,
        tools: tool_schemas(state.tool_specs, state.capabilities),
        system_prompt: effective_system_prompt(state)
    }
  end

  defp tool_schemas(modules, %{native_tool_calls: true}), do: Tools.describe_for_provider(modules)
  defp tool_schemas(_modules, _caps), do: nil

  defp effective_system_prompt(%State{capabilities: %{native_tool_calls: true}} = state),
    do: state.request_template.system_prompt

  defp effective_system_prompt(state) do
    ExAthena.ToolCalls.augment_system_prompt(
      state.request_template.system_prompt,
      Tools.describe_for_prompt(state.tool_specs)
    )
  end

  # ── Provider dispatch: query vs stream ────────────────────────────

  # When the caller registered `on_event`, stream the provider response and
  # forward `:text_delta` events to it in real time. Otherwise fall back to
  # a cheaper one-shot `query/2`.
  defp query_or_stream(%State{on_event: nil} = state, request) do
    state.provider_mod.query(request, state.provider_opts)
  end

  defp query_or_stream(%State{on_event: on_event} = state, request)
       when is_function(on_event, 1) do
    if function_exported?(state.provider_mod, :stream, 3) do
      state.provider_mod.stream(request, on_event, state.provider_opts)
    else
      state.provider_mod.query(request, state.provider_opts)
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value, pretty: true, limit: :infinity)

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
