defmodule ExAthena.Streaming do
  @moduledoc """
  Canonical streaming event types and the broadcaster helper.

  Providers emit events as tokens arrive. The `ExAthena` facade forwards them
  to the user-supplied callback. `ExAthena.Loop` consumes the same events to
  build up tool-call requests and decide when to stop, and re-emits tool
  activity (`:tool_call_start`, `:tool_result`) so hosts can render a live
  transcript of the run.
  """

  defmodule Event do
    @moduledoc "A single streaming event."

    @enforce_keys [:type]
    defstruct [:type, :data, :index]

    @type type ::
            :start
            | :text_delta
            | :thinking_delta
            | :tool_call_start
            | :tool_call_delta
            | :tool_call_end
            | :tool_result
            | :usage
            | :stop
            | :error

    @type t :: %__MODULE__{
            type: type(),
            data: term(),
            index: non_neg_integer() | nil
          }
  end

  @doc "Emit a text-delta event."
  def text_delta(callback, text) when is_binary(text),
    do: emit(callback, %Event{type: :text_delta, data: text})

  @doc "Emit a thinking/reasoning delta event (Claude `<thinking>` blocks, etc.)."
  def thinking_delta(callback, text) when is_binary(text),
    do: emit(callback, %Event{type: :thinking_delta, data: text})

  @doc "Emit a start-of-tool-call event with a partial ToolCall."
  def tool_call_start(callback, index, partial),
    do: emit(callback, %Event{type: :tool_call_start, index: index, data: partial})

  @doc "Emit a tool-call argument delta."
  def tool_call_delta(callback, index, delta),
    do: emit(callback, %Event{type: :tool_call_delta, index: index, data: delta})

  @doc "Emit a final tool-call event with the complete ToolCall."
  def tool_call_end(callback, index, tool_call),
    do: emit(callback, %Event{type: :tool_call_end, index: index, data: tool_call})

  @doc "Emit a completed tool-result event (providers whose runtime executes tools internally, e.g. Claude Code)."
  def tool_result(callback, tool_result),
    do: emit(callback, %Event{type: :tool_result, data: tool_result})

  @doc "Emit a usage-accounting event."
  def usage(callback, usage) when is_map(usage),
    do: emit(callback, %Event{type: :usage, data: usage})

  @doc "Emit a terminal stop event."
  def stop(callback, reason), do: emit(callback, %Event{type: :stop, data: reason})

  @doc "Emit a terminal error event."
  def error(callback, err), do: emit(callback, %Event{type: :error, data: err})

  defp emit(nil, _event), do: :ok

  defp emit(callback, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end
end
