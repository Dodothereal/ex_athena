defmodule ExAthena.Chat.Tui.State do
  @moduledoc """
  Pure state container for the `mix athena.chat` TUI.

  Wraps a `%ExAthena.Chat.Session{}` with UI-only fields (input, popup,
  scrollback, streaming buffer, etc.) and provides the transitions the
  `ExAthena.Chat.Tui` App calls from `mount/1`, `handle_event/2`, and
  `handle_info/2`.

  No ex_ratatui imports here — keeps tests fast and avoids dragging the
  NIF into pure-data unit tests.
  """

  alias ExAthena.Chat.Session
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result

  @preview_chars 200
  @default_footer "Enter: send  Ctrl+C: quit  /help"

  @type event_kind ::
          :user
          | :assistant
          | :tool_call
          | :tool_result
          | :tool_result_error
          | :error
          | :warning
          | :info
          | :status

  @type event_row :: {event_kind(), String.t()}

  @type popup ::
          nil
          | {:model, [String.t()], non_neg_integer()}
          | {:mode, [atom()], non_neg_integer()}

  defstruct session: nil,
            input_ref: nil,
            scroll_offset: 0,
            stream_buffer: "",
            loading?: false,
            popup: nil,
            events: [],
            footer: @default_footer,
            prior_log_level: :info,
            run_task: nil

  @type t :: %__MODULE__{
          session: Session.t(),
          input_ref: reference() | nil,
          scroll_offset: non_neg_integer(),
          stream_buffer: String.t(),
          loading?: boolean(),
          popup: popup(),
          events: [event_row()],
          footer: String.t(),
          prior_log_level: atom(),
          run_task: pid() | nil
        }

  @spec new(Session.t()) :: t()
  def new(%Session{} = session) do
    %__MODULE__{session: session, prior_log_level: Logger.level()}
  end

  @spec append_event(t(), event_row()) :: t()
  def append_event(%__MODULE__{events: events} = state, {kind, text} = row)
      when is_atom(kind) and is_binary(text) do
    %{state | events: events ++ [row]}
  end

  @doc """
  Apply an `ExAthena.Loop.Events.t()` to the UI state.

  `:content` deltas accumulate into `stream_buffer` and are materialized
  by `flush_stream/1` (the App calls this every tick). Other event kinds
  produce a row immediately. Silent events (`:iteration`, `:usage`,
  `:tool_ui`, `:done`) and unknown events are no-ops.
  """
  @spec append_loop_event(t(), term()) :: t()
  def append_loop_event(%__MODULE__{} = state, {:content, text}) when is_binary(text) do
    %{state | stream_buffer: state.stream_buffer <> text}
  end

  def append_loop_event(
        %__MODULE__{} = state,
        {:tool_call, %ToolCall{name: name, arguments: args}}
      ) do
    append_event(state, {:tool_call, "→ #{name}(#{preview_args(args)})"})
  end

  def append_loop_event(
        %__MODULE__{} = state,
        {:tool_result, %ToolResult{content: content, is_error: is_error}}
      ) do
    kind = if is_error, do: :tool_result_error, else: :tool_result
    append_event(state, {kind, "← #{summarize_result(content)}"})
  end

  def append_loop_event(%__MODULE__{} = state, {:error, reason}) do
    append_event(state, {:warning, "warn: #{inspect(reason)}"})
  end

  def append_loop_event(%__MODULE__{} = state, {:compaction, %{before: before, after: aft}}) do
    append_event(state, {:info, "⤵ compacted #{before}→#{aft} tokens"})
  end

  def append_loop_event(%__MODULE__{} = state, {:subagent_spawn, %{prompt: p}}) do
    append_event(state, {:info, "  ↳ subagent: #{truncate(p, 80)}"})
  end

  def append_loop_event(%__MODULE__{} = state, {:subagent_result, %{text: t}}) do
    append_event(state, {:info, "  ↳ subagent done: #{truncate(t, 80)}"})
  end

  def append_loop_event(%__MODULE__{} = state, _other), do: state

  @doc """
  Materialize `stream_buffer` into the events list and clear it.

  If the most recent event is already `:assistant`, the buffered text is
  appended to it (streaming continues into the same row). Otherwise a
  fresh `:assistant` row is created.
  """
  @spec flush_stream(t()) :: t()
  def flush_stream(%__MODULE__{stream_buffer: ""} = state), do: state

  def flush_stream(%__MODULE__{stream_buffer: buf, events: events} = state) do
    new_events =
      case Enum.reverse(events) do
        [{:assistant, prior} | rest] ->
          Enum.reverse([{:assistant, prior <> buf} | rest])

        _ ->
          events ++ [{:assistant, buf}]
      end

    %{state | events: new_events, stream_buffer: ""}
  end

  @spec set_loading(t(), boolean()) :: t()
  def set_loading(%__MODULE__{} = state, flag) when is_boolean(flag) do
    %{state | loading?: flag}
  end

  @spec apply_result(t(), Result.t()) :: t()
  def apply_result(%__MODULE__{session: session} = state, %Result{} = result) do
    %{state | session: Session.apply_result(session, result)}
  end

  @spec set_model(t(), String.t()) :: t()
  def set_model(%__MODULE__{session: session} = state, model) when is_binary(model) do
    %{state | session: Session.set_model(session, model)}
  end

  @spec set_mode(t(), atom()) :: t()
  def set_mode(%__MODULE__{session: session} = state, mode) when is_atom(mode) do
    %{state | session: Session.set_mode(session, mode)}
  end

  @spec clear_session(t()) :: t()
  def clear_session(%__MODULE__{session: session} = state) do
    %{state | session: Session.clear_messages(session), events: [], stream_buffer: ""}
  end

  # ─ Popups ─────────────────────────────────────────────────────────────────

  @spec open_popup(t(), {:model, [String.t()]} | {:mode, [atom()]}) :: t()
  def open_popup(%__MODULE__{} = state, {kind, items})
      when kind in [:model, :mode] and is_list(items) do
    %{state | popup: {kind, items, 0}}
  end

  @spec close_popup(t()) :: t()
  def close_popup(%__MODULE__{} = state), do: %{state | popup: nil}

  @spec move_popup_selection(t(), integer()) :: t()
  def move_popup_selection(%__MODULE__{popup: nil} = state, _delta), do: state
  def move_popup_selection(%__MODULE__{popup: {_, [], _}} = state, _delta), do: state

  def move_popup_selection(%__MODULE__{popup: {kind, items, idx}} = state, delta)
      when is_integer(delta) do
    n = length(items)
    new_idx = Integer.mod(idx + delta, n)
    %{state | popup: {kind, items, new_idx}}
  end

  @spec current_popup_selection(t()) :: any() | nil
  def current_popup_selection(%__MODULE__{popup: nil}), do: nil
  def current_popup_selection(%__MODULE__{popup: {_, [], _}}), do: nil
  def current_popup_selection(%__MODULE__{popup: {_, items, idx}}), do: Enum.at(items, idx)

  # ─ Helpers ────────────────────────────────────────────────────────────────

  defp summarize_result(content) do
    text = content |> to_string() |> String.trim_trailing("\n")
    lines = String.split(text, "\n")
    first_line = lines |> List.first("") |> truncate(@preview_chars)

    case length(lines) do
      1 -> first_line
      n -> "#{first_line} · #{n} lines"
    end
  end

  defp preview_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp preview_args(args) when is_map(args) do
    Enum.map_join(args, ", ", fn {k, v} -> "#{k}: #{truncate(inspect_value(v), 60)}" end)
  end

  defp preview_args(other), do: inspect(other)

  defp inspect_value(v) when is_binary(v), do: inspect(v)
  defp inspect_value(v), do: inspect(v, limit: 5, printable_limit: 60)

  defp truncate(text, limit) when is_binary(text) do
    case String.length(text) do
      n when n <= limit -> text
      _ -> String.slice(text, 0, limit) <> "…"
    end
  end

  defp truncate(other, limit), do: truncate(to_string(other), limit)
end
