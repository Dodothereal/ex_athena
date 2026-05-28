defmodule ExAthena.Telemetry do
  @moduledoc """
  Telemetry emission for ExAthena, shaped to the OpenTelemetry GenAI
  semantic conventions so consumers can plug directly into OTel without
  a translation layer.

  ## Events

  All events use the standard `:telemetry` library — attach handlers with
  `:telemetry.attach/4` or use `opentelemetry_telemetry` for OTel.

    * `[:ex_athena, :loop, :start]` — a `Loop.run/2` began.
    * `[:ex_athena, :loop, :stop]` — the loop terminated. Measurements
      include `:duration_ms`, `:iterations`, `:tool_calls_made`,
      `:cost_usd`. Metadata includes the full `%Result{}`.
    * `[:ex_athena, :loop, :exception]` — an unhandled error bubbled out.
    * `[:ex_athena, :chat, :start]` — a single provider call began.
    * `[:ex_athena, :chat, :stop]` — the provider call returned.
      Measurements include `:duration_ms`, `:input_tokens`,
      `:output_tokens`, `:total_tokens`.
    * `[:ex_athena, :tool, :start]` — a tool invocation began.
    * `[:ex_athena, :tool, :stop]` — the tool invocation finished.
      Measurements include `:duration_ms`. Metadata includes `:is_error`.
    * `[:ex_athena, :compaction, :stop]` — a compaction pass completed.
      Measurements include `:before_tokens`, `:after_tokens`,
      `:dropped_count`.
    * `[:ex_athena, :subagent, :spawn]` / `[:ex_athena, :subagent, :stop]`
      — a subagent was spawned / returned.
    * `[:ex_athena, :structured_retry]` — a structured-output repair
      attempt fired. Measurements include `:attempt`.
    * `[:ex_athena, :request_queue, :wait]` — a call is about to attempt
      acquiring a request-queue slot. Metadata includes `:provider`.
    * `[:ex_athena, :request_queue, :acquired]` — a slot was granted.
      Metadata includes `:provider`.
    * `[:ex_athena, :request_queue, :released]` — a slot was released after
      the call completed (success, error, or exception). Metadata includes
      `:provider`.
    * `[:ex_athena, :request_queue, :timeout]` — acquiring a slot timed out;
      the call returns `{:error, :request_queue_timeout}`. Metadata includes
      `:provider`.

  ## GenAI semconv metadata

  Event metadata uses GenAI semantic-convention attribute keys where they
  apply. The key Elixir-atom form mirrors the OTel dotted-path form:

    * `:gen_ai_operation_name` — `"chat"`, `"invoke_agent"`, `"execute_tool"`
    * `:gen_ai_provider_name` — e.g. `"openai"`, `"anthropic"`, `"ollama"`
    * `:gen_ai_request_model` — the model requested
    * `:gen_ai_response_model` — the model the response identified as
    * `:gen_ai_agent_id` — an optional agent identifier
    * `:gen_ai_conversation_id` — stable per-session identifier
    * `:gen_ai_usage_input_tokens`, `:gen_ai_usage_output_tokens`
    * `:gen_ai_tool_name`, `:gen_ai_tool_call_id`
    * `:gen_ai_response_finish_reasons` — list, e.g. `[:stop]`

  Consumers bridging to OTel should translate these atoms to the dotted
  OTel names (`gen_ai.operation.name`, etc.); `opentelemetry_telemetry`
  handles this automatically if you point it at the events above.
  """

  @doc """
  Execute `fun/0` inside a `[:ex_athena, name, ...]` span.

  Emits `:start`, then `:stop` (or `:exception` on raise) with GenAI
  metadata merged in. Returns `fun`'s result unchanged.
  """
  @spec span([atom()], map(), (-> term())) :: term()
  def span(prefix, meta \\ %{}, fun) when is_list(prefix) and is_function(fun, 0) do
    start_time = System.monotonic_time()
    start_meta = Map.merge(meta, %{system_time: System.system_time()})

    :telemetry.execute(prefix ++ [:start], %{system_time: start_meta.system_time}, meta)

    try do
      result = fun.()
      duration_native = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

      :telemetry.execute(
        prefix ++ [:stop],
        %{duration_ms: duration_ms, duration_native: duration_native},
        Map.put(meta, :result, result)
      )

      result
    rescue
      exc ->
        duration_ms =
          System.convert_time_unit(
            System.monotonic_time() - start_time,
            :native,
            :millisecond
          )

        :telemetry.execute(
          prefix ++ [:exception],
          %{duration_ms: duration_ms},
          Map.merge(meta, %{kind: :error, reason: exc, stacktrace: __STACKTRACE__})
        )

        reraise exc, __STACKTRACE__
    end
  end

  @doc """
  Emit a single telemetry event (no timing). Convenience for discrete
  events like `:structured_retry`, `:subagent_spawn`, `:compaction_stop`.
  """
  @spec event([atom()], map(), map()) :: :ok
  def event(name, measurements \\ %{}, meta \\ %{}) when is_list(name) do
    :telemetry.execute(name, measurements, meta)
  end

  @doc """
  Build a GenAI-semconv-shaped metadata map from common loop inputs.

  Use this to produce a consistent metadata surface across emitters.
  """
  @spec genai_meta(keyword()) :: map()
  def genai_meta(opts) do
    opts
    |> Enum.reduce(%{}, fn
      {:operation, v}, acc -> Map.put(acc, :gen_ai_operation_name, v)
      {:provider, v}, acc -> Map.put(acc, :gen_ai_provider_name, to_name(v))
      {:request_model, v}, acc -> Map.put(acc, :gen_ai_request_model, v)
      {:response_model, v}, acc -> Map.put(acc, :gen_ai_response_model, v)
      {:agent_id, v}, acc -> Map.put(acc, :gen_ai_agent_id, v)
      {:conversation_id, v}, acc -> Map.put(acc, :gen_ai_conversation_id, v)
      {:tool_name, v}, acc -> Map.put(acc, :gen_ai_tool_name, v)
      {:tool_call_id, v}, acc -> Map.put(acc, :gen_ai_tool_call_id, v)
      {:input_tokens, v}, acc -> Map.put(acc, :gen_ai_usage_input_tokens, v)
      {:output_tokens, v}, acc -> Map.put(acc, :gen_ai_usage_output_tokens, v)
      {:finish_reasons, v}, acc -> Map.put(acc, :gen_ai_response_finish_reasons, List.wrap(v))
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp to_name(v) when is_atom(v), do: Atom.to_string(v)
  defp to_name(v) when is_binary(v), do: v
  defp to_name(v), do: inspect(v)
end
