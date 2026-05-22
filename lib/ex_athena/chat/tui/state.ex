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

  alias ExAthena.Chat.{Commands, Session}
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result
  alias ExAthena.Streaming.Event, as: StreamEvent

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
          | :thinking
          | :detail_header

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
            details: [],
            details_scroll_offset: 0,
            details_stream_buffer: "",
            details_thinking_buffer: "",
            thinking_open?: false,
            show_details: true,
            # Streaming-tag parser state. Tracks whether we're currently
            # inside a `<think>` block and holds the longest suffix of the
            # latest delta that could be the start of an open/close tag
            # (so partial tags spanning deltas still parse correctly).
            stream_parser: %{mode: :outside, pending: "", close_tag: nil},
            # True once any per-token streaming delta has arrived this turn.
            # When true we suppress the redundant end-of-turn
            # `{:content,...}` / `{:thinking,...}` loop events that the
            # mode emits with the full accumulated text.
            streamed_this_turn?: false,
            # Slash-command autocomplete state. Open when the textarea
            # starts with `/` and has no whitespace yet — the user is
            # mid-verb. `items` are slash-prefixed verbs; `idx` is the
            # selected row (0-based).
            autocomplete: nil,
            # Which tab is active in the right details pane.
            details_tab: :timeline,
            # Lines of `git diff HEAD` for the :changes tab. Refreshed
            # asynchronously after every tool result and on /cd.
            git_diff_lines: [],
            git_diff_scroll_offset: 0,
            footer: @default_footer,
            prior_log_level: :info,
            run_task: nil

  @type autocomplete ::
          nil | %{required(:items) => [String.t()], required(:idx) => non_neg_integer()}

  @type t :: %__MODULE__{
          session: Session.t(),
          input_ref: reference() | nil,
          scroll_offset: non_neg_integer(),
          stream_buffer: String.t(),
          loading?: boolean(),
          popup: popup(),
          events: [event_row()],
          details: [event_row()],
          details_scroll_offset: non_neg_integer(),
          details_stream_buffer: String.t(),
          details_thinking_buffer: String.t(),
          thinking_open?: boolean(),
          show_details: boolean(),
          stream_parser: %{mode: atom(), pending: String.t(), close_tag: String.t() | nil},
          streamed_this_turn?: boolean(),
          autocomplete: autocomplete(),
          details_tab: :timeline | :changes,
          git_diff_lines: [String.t()],
          git_diff_scroll_offset: non_neg_integer(),
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

  `:content` deltas accumulate into `stream_buffer` (left pane) and
  `details_stream_buffer` (right pane); both are materialized by
  `flush_stream/1`. Most other events produce a one-line row in the
  left pane and a full-detail block in the right pane.
  """
  @spec append_loop_event(t(), term()) :: t()
  # Per-token streaming text delta (arrives via the provider during
  # inference, before the loop emits its final {:content, ...} event).
  # Run it through the inline <think>...</think> parser so thinking is
  # routed to the right pane in real time.
  def append_loop_event(%__MODULE__{} = state, %StreamEvent{type: :text_delta, data: text})
      when is_binary(text) do
    {new_parser, content_chunk, thinking_chunk} = parse_stream_chunk(state.stream_parser, text)

    %{
      state
      | stream_parser: new_parser,
        streamed_this_turn?: true,
        stream_buffer: state.stream_buffer <> content_chunk,
        details_stream_buffer: state.details_stream_buffer <> content_chunk,
        details_thinking_buffer: state.details_thinking_buffer <> thinking_chunk
    }
  end

  # Per-token native thinking delta (Claude `<thinking>` blocks via
  # req_llm). Routes straight to the thinking buffer.
  def append_loop_event(%__MODULE__{} = state, %StreamEvent{type: :thinking_delta, data: text})
      when is_binary(text) do
    %{
      state
      | streamed_this_turn?: true,
        details_thinking_buffer: state.details_thinking_buffer <> text
    }
  end

  # Ignore other Streaming.Event kinds (start, tool_call_*, usage, stop,
  # error). The agent loop translates the relevant ones into loop event
  # tuples that we handle below.
  def append_loop_event(%__MODULE__{} = state, %StreamEvent{}), do: state

  # When per-token streaming already populated the buffers this turn,
  # the mode's end-of-turn {:content, full_text} would duplicate it.
  # Drop it (the streamed content is the source of truth).
  def append_loop_event(%__MODULE__{streamed_this_turn?: true} = state, {:content, _text}) do
    state
  end

  def append_loop_event(%__MODULE__{streamed_this_turn?: true} = state, {:thinking, _text}) do
    state
  end

  def append_loop_event(%__MODULE__{} = state, {:content, text}) when is_binary(text) do
    {thinking, content} = split_thinking_blocks(text)

    %{
      state
      | stream_buffer: state.stream_buffer <> content,
        details_stream_buffer: state.details_stream_buffer <> content,
        details_thinking_buffer: state.details_thinking_buffer <> thinking
    }
  end

  def append_loop_event(%__MODULE__{} = state, {:thinking, text}) when is_binary(text) do
    %{state | details_thinking_buffer: state.details_thinking_buffer <> text}
  end

  def append_loop_event(
        %__MODULE__{} = state,
        {:tool_call, %ToolCall{name: name, arguments: args}}
      ) do
    state
    |> append_event({:tool_call, "→ #{name}(#{preview_args(args)})"})
    |> append_detail_header("→ #{name}")
    |> append_detail_lines(:tool_call, format_args_full(args))
  end

  def append_loop_event(
        %__MODULE__{} = state,
        {:tool_result, %ToolResult{content: content, is_error: is_error}}
      ) do
    kind = if is_error, do: :tool_result_error, else: :tool_result
    arrow = if is_error, do: "✗", else: "←"

    state
    |> append_event({kind, "← #{summarize_result(content)}"})
    |> append_detail_header("#{arrow} result")
    |> append_detail_lines(kind, to_string(content))
  end

  def append_loop_event(%__MODULE__{} = state, {:tool_ui, %{kind: kind, payload: payload}}) do
    state
    |> append_detail_header("ui · #{kind}")
    |> append_detail_lines(:info, format_tool_ui(kind, payload))
  end

  def append_loop_event(%__MODULE__{} = state, {:iteration, n}) do
    append_detail_header(state, "iteration #{n}")
  end

  def append_loop_event(%__MODULE__{} = state, {:compaction, %{before: before, after: aft}}) do
    state
    |> append_event({:info, "⤵ compacted #{before}→#{aft} tokens"})
    |> append_detail_header("⤵ compacted #{before}→#{aft} tokens")
  end

  def append_loop_event(%__MODULE__{} = state, {:subagent_spawn, %{prompt: p}}) do
    state
    |> append_event({:info, "  ↳ subagent: #{truncate(p, 80)}"})
    |> append_detail_header("↳ subagent spawn")
    |> append_detail_lines(:info, p)
  end

  def append_loop_event(%__MODULE__{} = state, {:subagent_result, %{text: t}}) do
    state
    |> append_event({:info, "  ↳ subagent done: #{truncate(t, 80)}"})
    |> append_detail_header("↳ subagent result")
    |> append_detail_lines(:info, t)
  end

  def append_loop_event(%__MODULE__{} = state, {:error, reason}) do
    state
    |> append_event({:warning, "warn: #{inspect(reason)}"})
    |> append_detail_header("⚠ error")
    |> append_detail_lines(:error, inspect(reason, pretty: true))
  end

  def append_loop_event(%__MODULE__{} = state, {:usage, usage}) do
    append_detail_header(state, "usage · #{inspect(usage)}")
  end

  def append_loop_event(%__MODULE__{} = state, _other), do: state

  @doc """
  Materialize `stream_buffer` into the events list, and the
  `details_stream_buffer` / `details_thinking_buffer` into the details
  list. Clears all three buffers.

  For each pane, if the most recent row is already the same kind
  (`:assistant` / `:thinking`), the buffered text is appended in place.
  Otherwise a fresh row is started.
  """
  @spec flush_stream(t()) :: t()
  def flush_stream(%__MODULE__{} = state) do
    state
    |> flush_main_stream()
    |> flush_details_assistant_stream()
    |> flush_details_thinking_stream()
  end

  defp flush_main_stream(%__MODULE__{stream_buffer: ""} = state), do: state

  defp flush_main_stream(%__MODULE__{stream_buffer: buf, events: events} = state) do
    new_events =
      case Enum.reverse(events) do
        [{:assistant, prior} | rest] ->
          Enum.reverse([{:assistant, prior <> buf} | rest])

        _ ->
          events ++ [{:assistant, buf}]
      end

    %{state | events: new_events, stream_buffer: ""}
  end

  defp flush_details_assistant_stream(%__MODULE__{details_stream_buffer: ""} = state), do: state

  defp flush_details_assistant_stream(%__MODULE__{details_stream_buffer: buf} = state) do
    state
    |> merge_details_buffer(:assistant, buf)
    |> Map.put(:details_stream_buffer, "")
  end

  defp flush_details_thinking_stream(%__MODULE__{details_thinking_buffer: ""} = state), do: state

  defp flush_details_thinking_stream(%__MODULE__{details_thinking_buffer: buf} = state) do
    state
    |> merge_details_buffer(:thinking, buf)
    |> Map.put(:details_thinking_buffer, "")
  end

  # Append `buf` to the last detail row of the given kind if it's the tail
  # (continuing a stream), otherwise start a new block. The buffer is
  # split into one detail row per source line so the right pane wraps
  # naturally with one widget per row.
  defp merge_details_buffer(%__MODULE__{details: details} = state, kind, buf) do
    new_lines = split_lines(buf)

    new_details =
      case {Enum.reverse(details), new_lines} do
        {[{^kind, prior} | rest], [first | more]} ->
          merged_first = {kind, prior <> first}
          Enum.reverse([merged_first | rest]) ++ Enum.map(more, &{kind, &1})

        _ ->
          details ++ Enum.map(new_lines, &{kind, &1})
      end

    %{state | details: new_details}
  end

  defp split_lines(""), do: [""]
  defp split_lines(text), do: String.split(text, "\n")

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
    %{
      state
      | session: Session.clear_messages(session),
        events: [],
        stream_buffer: "",
        details: [],
        details_scroll_offset: 0,
        details_stream_buffer: "",
        details_thinking_buffer: "",
        stream_parser: %{mode: :outside, pending: "", close_tag: nil},
        streamed_this_turn?: false,
        autocomplete: nil
    }
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

  # ─ Details-pane tabs (timeline / changes) ────────────────────────────────

  @details_tabs [:timeline, :changes]

  @doc "Returns the ordered list of tab atoms used in the details pane."
  @spec details_tabs() :: [atom()]
  def details_tabs, do: @details_tabs

  @doc "Switch to the next tab in order, wrapping to the first."
  @spec cycle_details_tab(t()) :: t()
  def cycle_details_tab(%__MODULE__{details_tab: tab} = state) do
    idx = Enum.find_index(@details_tabs, &(&1 == tab)) || 0
    next = Enum.at(@details_tabs, Integer.mod(idx + 1, length(@details_tabs)))
    %{state | details_tab: next}
  end

  @spec set_details_tab(t(), atom()) :: t()
  def set_details_tab(%__MODULE__{} = state, tab) when tab in @details_tabs do
    %{state | details_tab: tab}
  end

  @doc "Replace the cached `git diff` output with a fresh list of lines."
  @spec set_git_diff(t(), [String.t()]) :: t()
  def set_git_diff(%__MODULE__{} = state, lines) when is_list(lines) do
    %{state | git_diff_lines: lines}
  end

  # ─ Slash-command autocomplete ────────────────────────────────────────────

  @doc """
  Recompute the autocomplete suggestions from the current textarea value.
  Opens the popup when the value starts with `/` and has no whitespace
  yet (the user is typing the verb). Closes it otherwise. Preserves the
  selected index when possible so re-rendering doesn't jump it.
  """
  @spec update_autocomplete(t(), String.t()) :: t()
  def update_autocomplete(%__MODULE__{} = state, value) when is_binary(value) do
    %{state | autocomplete: autocomplete_for(value, state.autocomplete)}
  end

  @doc false
  def autocomplete_for(value, prior \\ nil)

  def autocomplete_for("/" <> rest = _value, prior) when rest != "" do
    if String.match?(rest, ~r/\s/) do
      nil
    else
      build_autocomplete(rest, prior)
    end
  end

  def autocomplete_for("/", prior) do
    # Bare slash — show every verb.
    build_autocomplete("", prior)
  end

  def autocomplete_for(_value, _prior), do: nil

  defp build_autocomplete(rest, prior) do
    needle = String.downcase(rest)

    items =
      Commands.verbs()
      |> Enum.filter(fn "/" <> verb -> String.starts_with?(verb, needle) end)

    case items do
      [] ->
        nil

      _ ->
        # Preserve the selected verb across keystrokes when it's still
        # in the filtered list; otherwise reset to 0.
        idx =
          case prior do
            %{items: prior_items, idx: prior_idx} ->
              case Enum.at(prior_items, prior_idx) do
                nil -> 0
                selected -> Enum.find_index(items, &(&1 == selected)) || 0
              end

            _ ->
              0
          end

        %{items: items, idx: idx}
    end
  end

  @doc "Move the autocomplete selection by `delta` (wraps top/bottom)."
  @spec move_autocomplete(t(), integer()) :: t()
  def move_autocomplete(%__MODULE__{autocomplete: nil} = state, _delta), do: state

  def move_autocomplete(%__MODULE__{autocomplete: %{items: items, idx: idx}} = state, delta)
      when is_integer(delta) do
    n = length(items)
    new_idx = Integer.mod(idx + delta, n)
    %{state | autocomplete: %{items: items, idx: new_idx}}
  end

  @doc "Return the currently-selected autocomplete entry (or nil)."
  @spec selected_autocomplete(t()) :: String.t() | nil
  def selected_autocomplete(%__MODULE__{autocomplete: nil}), do: nil

  def selected_autocomplete(%__MODULE__{autocomplete: %{items: items, idx: idx}}),
    do: Enum.at(items, idx)

  @doc "Clear the autocomplete popup state."
  @spec close_autocomplete(t()) :: t()
  def close_autocomplete(%__MODULE__{} = state), do: %{state | autocomplete: nil}

  # ─ Streaming-tag parser ──────────────────────────────────────────────────

  @open_re ~r/<think(?:ing)?>/
  @open_candidates ["<think>", "<thinking>"]

  @doc """
  Reset the streaming parser state at the start of a new turn.
  Called by `Tui.dispatch_message/2` before issuing the next request.
  """
  @spec reset_stream_state(t()) :: t()
  def reset_stream_state(%__MODULE__{} = state) do
    %{
      state
      | stream_parser: %{mode: :outside, pending: "", close_tag: nil},
        streamed_this_turn?: false
    }
  end

  # Run a streaming text delta through the inline-think state machine.
  # Returns `{new_parser, content_chunk, thinking_chunk}`. The parser
  # holds a `pending` string — the longest suffix of the previous delta
  # that could be the start of a candidate tag — so tags split across
  # deltas (`"…<thi"` + `"nk>foo</think>"`) still parse correctly.
  @doc false
  def parse_stream_chunk(parser, chunk) when is_binary(chunk) do
    do_parse_stream(parser, chunk, "", "")
  end

  defp do_parse_stream(parser, "", content_acc, thinking_acc),
    do: {parser, content_acc, thinking_acc}

  defp do_parse_stream(%{mode: :outside, pending: pending}, chunk, content_acc, thinking_acc) do
    text = pending <> chunk

    case Regex.split(@open_re, text, parts: 2, include_captures: true) do
      [before, tag, rest] ->
        close_tag = if tag == "<think>", do: "</think>", else: "</thinking>"
        next = %{mode: :inside, pending: "", close_tag: close_tag}
        do_parse_stream(next, rest, content_acc <> before, thinking_acc)

      [single] ->
        {pending_tail, emit} = split_pending_tail(single, @open_candidates)
        next = %{mode: :outside, pending: pending_tail, close_tag: nil}
        {next, content_acc <> emit, thinking_acc}
    end
  end

  defp do_parse_stream(
         %{mode: :inside, pending: pending, close_tag: close_tag},
         chunk,
         content_acc,
         thinking_acc
       ) do
    text = pending <> chunk

    case String.split(text, close_tag, parts: 2) do
      [before, rest] ->
        next = %{mode: :outside, pending: "", close_tag: nil}
        do_parse_stream(next, rest, content_acc, thinking_acc <> before)

      [single] ->
        {pending_tail, emit} = split_pending_tail(single, [close_tag])
        next = %{mode: :inside, pending: pending_tail, close_tag: close_tag}
        {next, content_acc, thinking_acc <> emit}
    end
  end

  # Split `text` into `{pending_tail, emit}` where `pending_tail` is the
  # longest suffix of `text` that is a STRICT prefix of any candidate
  # tag (e.g. "<thi" when the candidate is "<think>"). Everything before
  # the partial is safe to emit; the partial is held until the next
  # delta arrives.
  defp split_pending_tail(text, candidates) do
    text_len = byte_size(text)
    max_n = candidates |> Enum.map(&byte_size/1) |> Enum.max() |> Kernel.-(1) |> min(text_len)

    pending =
      Enum.reduce_while(max_n..1//-1, "", fn n, _ ->
        suffix = binary_part(text, text_len - n, n)

        if Enum.any?(candidates, &String.starts_with?(&1, suffix)),
          do: {:halt, suffix},
          else: {:cont, ""}
      end)

    if pending == "" do
      {"", text}
    else
      {pending, binary_part(text, 0, text_len - byte_size(pending))}
    end
  end

  # ─ Thinking-tag extraction (one-shot, end-of-turn) ───────────────────────

  # Used by the existing {:content, text} handler when streaming wasn't
  # available (provider supports only query/2, not stream/3). Matches
  # `<think>` AND `<thinking>` to cover the common variants; `s` flag so
  # `.` spans newlines.
  @think_re ~r/<think(?:ing)?>(.*?)<\/think(?:ing)?>/s

  @doc false
  def split_thinking_blocks(text) when is_binary(text) do
    case Regex.scan(@think_re, text, capture: :all_but_first) do
      [] ->
        {"", text}

      matches ->
        thinking = matches |> List.flatten() |> Enum.join("\n")
        content = Regex.replace(@think_re, text, "") |> String.trim()
        {thinking, content}
    end
  end

  # ─ Details-pane helpers ──────────────────────────────────────────────────

  @doc false
  def append_detail_header(%__MODULE__{details: details} = state, label)
      when is_binary(label) do
    %{state | details: details ++ [{:detail_header, label}]}
  end

  @doc false
  def append_detail_lines(%__MODULE__{details: details} = state, kind, text)
      when is_atom(kind) do
    rows =
      text
      |> to_string()
      |> String.trim_trailing("\n")
      |> String.split("\n")
      |> Enum.map(&{kind, &1})

    %{state | details: details ++ rows}
  end

  defp format_args_full(args) when is_map(args) do
    case Jason.encode(args, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(args, pretty: true, limit: :infinity)
    end
  end

  defp format_args_full(other), do: inspect(other, pretty: true)

  defp format_tool_ui(:diff, %{path: path, before: before, after: aft}) do
    "diff: #{path}\n--- before\n#{before}\n+++ after\n#{aft}"
  end

  defp format_tool_ui(:process, %{command: cmd, exit_code: code, stdout: out, duration_ms: ms}) do
    "$ #{cmd}\n[exit=#{code}, #{ms}ms]\n#{out}"
  end

  defp format_tool_ui(:file, %{path: path, content: content}) do
    "file: #{path}\n#{content}"
  end

  defp format_tool_ui(kind, payload), do: "#{kind}: #{inspect(payload, pretty: true)}"

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
