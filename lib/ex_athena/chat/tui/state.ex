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

  @default_footer "Enter: send  Ctrl+C: quit  /help"

  @type event_kind ::
          :user
          | :assistant
          | :tool_call
          | :tool_result
          | :tool_result_error
          | :tool_block
          | :error
          | :warning
          | :info
          | :status
          | :thinking
          | :detail_header

  @type event_row :: {event_kind(), term()}

  @type popup ::
          nil
          | {:model, [String.t()], non_neg_integer()}
          | {:mode, [atom()], non_neg_integer()}
          | {:provider, [{String.t(), String.t()}], non_neg_integer()}

  defstruct session: nil,
            input_ref: nil,
            scroll_offset: 0,
            # Manual scroll offsets. `nil` means "auto-pin to the bottom"
            # (the default — new content stays in view). Set to an
            # integer row count by PgUp/PgDn. End or a new user submit
            # resets back to nil.
            messages_scroll: nil,
            details_scroll: nil,
            stream_buffer: "",
            loading?: false,
            popup: nil,
            events: [],
            # Structured tool-call records keyed by tool_call_id. Events
            # carry only a `{:tool_block, id}` reference; State holds the
            # rich data (status, output preview, todos…) so the renderer
            # can lay out a unified "● Tool(args) / └ output" block.
            tool_blocks: %{},
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
            # Up/Down history cursor for the input. `nil` = not navigating
            # (the user is typing fresh); an integer N = the Nth-most-recent
            # prior user message (0 = newest). `history_draft` holds whatever
            # was in the textarea before navigation started so Down can
            # restore it.
            history_idx: nil,
            history_draft: "",
            # Whether crossterm mouse reporting is currently enabled. We
            # turn it on at App start via ANSI on /dev/tty (see Tui.start/1)
            # and let the user toggle with /mouse so they can drop back to
            # native terminal text selection.
            mouse_enabled: true,
            # Which tab is active in the right details pane.
            details_tab: :timeline,
            # Lines of `git diff HEAD` for the :changes tab. Refreshed
            # asynchronously after every tool result and on /cd.
            git_diff_lines: [],
            git_diff_scroll_offset: 0,
            # How the Changes tab renders its diff:
            #   :inline       — traditional unified diff (default)
            #   :side_by_side — two-column old / new
            diff_mode: :inline,
            footer: @default_footer,
            prior_log_level: :info,
            run_task: nil,
            api_key: nil,
            api_key_pending: false,
            pending_message: nil

  @type autocomplete ::
          nil | %{required(:items) => [String.t()], required(:idx) => non_neg_integer()}

  @type t :: %__MODULE__{
          session: Session.t(),
          input_ref: reference() | nil,
          scroll_offset: non_neg_integer(),
          messages_scroll: non_neg_integer() | nil,
          details_scroll: non_neg_integer() | nil,
          stream_buffer: String.t(),
          loading?: boolean(),
          popup: popup(),
          events: [event_row()],
          tool_blocks: %{String.t() => map()},
          details: [event_row()],
          details_scroll_offset: non_neg_integer(),
          details_stream_buffer: String.t(),
          details_thinking_buffer: String.t(),
          thinking_open?: boolean(),
          show_details: boolean(),
          stream_parser: %{mode: atom(), pending: String.t(), close_tag: String.t() | nil},
          streamed_this_turn?: boolean(),
          autocomplete: autocomplete(),
          history_idx: non_neg_integer() | nil,
          history_draft: String.t(),
          mouse_enabled: boolean(),
          details_tab: :timeline | :changes,
          git_diff_lines: [String.t()],
          git_diff_scroll_offset: non_neg_integer(),
          diff_mode: :inline | :side_by_side,
          footer: String.t(),
          prior_log_level: atom(),
          run_task: pid() | nil,
          api_key: String.t() | nil,
          api_key_pending: boolean(),
          pending_message: String.t() | nil
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
        {:tool_call, %ToolCall{id: id, name: name, arguments: args}}
      ) do
    block = %{
      id: id,
      name: name,
      args: args,
      status: :pending,
      output_preview: nil,
      total_lines: 0,
      total_bytes: 0,
      todos: parse_todos_from_call(name, args)
    }

    state
    |> Map.update!(:tool_blocks, &Map.put(&1, id, block))
    |> append_event({:tool_block, id})
    |> append_detail_header("→ #{name}")
    |> append_detail_lines(:tool_call, format_args_full(args))
  end

  def append_loop_event(
        %__MODULE__{} = state,
        {:tool_result, %ToolResult{tool_call_id: id, content: content, is_error: is_error} = tr}
      ) do
    content_str = to_string(content)
    status = if is_error, do: :error, else: :success
    {preview, total_lines} = preview_lines(content_str)
    arrow = if is_error, do: "✗", else: "←"

    detail_kind = if is_error, do: :tool_result_error, else: :tool_result

    state
    |> Map.update!(:tool_blocks, fn blocks ->
      case Map.get(blocks, id) do
        nil ->
          # No matching call (shouldn't happen, but stay defensive).
          Map.put(blocks, id, %{
            id: id,
            name: maybe_get_field(tr, :name) || "?",
            args: %{},
            status: status,
            output_preview: preview,
            total_lines: total_lines,
            total_bytes: byte_size(content_str),
            todos: nil
          })

        block ->
          Map.put(blocks, id, %{
            block
            | status: status,
              output_preview: preview,
              total_lines: total_lines,
              total_bytes: byte_size(content_str)
          })
      end
    end)
    |> append_detail_header("#{arrow} result")
    |> append_detail_lines(detail_kind, content_str)
  end

  def append_loop_event(%__MODULE__{} = state, {:tool_ui, %{kind: kind, payload: payload} = ui}) do
    state
    |> attach_tool_ui_to_block(ui)
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

  @spec set_provider(t(), atom()) :: t()
  def set_provider(%__MODULE__{session: session} = state, provider) when is_atom(provider) do
    %{state | session: Session.set_provider(session, provider)}
  end

  @spec set_api_key(t(), String.t()) :: t()
  def set_api_key(%__MODULE__{} = state, key) when is_binary(key) do
    %{state | api_key: key, api_key_pending: false}
  end

  @spec clear_session(t()) :: t()
  def clear_session(%__MODULE__{session: session} = state) do
    %{
      state
      | session: Session.clear_messages(session),
        events: [],
        tool_blocks: %{},
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

  @spec open_popup(
          t(),
          {:model, [String.t()]} | {:mode, [atom()]} | {:provider, [{String.t(), String.t()}]}
        ) :: t()
  def open_popup(%__MODULE__{} = state, {kind, items})
      when kind in [:model, :mode] and is_list(items) do
    %{state | popup: {kind, items, 0}}
  end

  def open_popup(%__MODULE__{} = state, {:provider, items}) when is_list(items) do
    %{state | popup: {:provider, items, 0}}
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

  def current_popup_selection(%__MODULE__{popup: {:provider, items, idx}}) do
    case Enum.at(items, idx) do
      {name, _display} -> name
      other -> other
    end
  end

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

  @doc "Set the Changes tab's diff layout (`:inline` or `:side_by_side`)."
  @spec set_diff_mode(t(), :inline | :side_by_side) :: t()
  def set_diff_mode(%__MODULE__{} = state, mode) when mode in [:inline, :side_by_side] do
    %{state | diff_mode: mode}
  end

  @doc "Toggle the Changes tab's diff layout."
  @spec cycle_diff_mode(t()) :: t()
  def cycle_diff_mode(%__MODULE__{diff_mode: :inline} = state),
    do: %{state | diff_mode: :side_by_side}

  def cycle_diff_mode(%__MODULE__{} = state),
    do: %{state | diff_mode: :inline}

  # ─ Pane scrolling ────────────────────────────────────────────────────────

  # Scrolling model: `messages_scroll` / `details_scroll` count the number
  # of rows the user has scrolled *above the natural bottom* of the pane.
  #
  #   nil / 0    → at the bottom (auto-follow new content)
  #   N > 0      → N rows above the bottom
  #
  # View resolves this each frame as `effective = max(auto_bottom - N, 0)`,
  # so we never need to know the viewport size in State.

  @doc """
  Move the messages pane. `delta < 0` scrolls up (older content),
  `delta > 0` scrolls down. Returns to the bottom when the offset would
  go below 0. Idempotent at the top.
  """
  @spec scroll_messages(t(), integer()) :: t()
  def scroll_messages(%__MODULE__{} = state, delta) when is_integer(delta) do
    cur = state.messages_scroll || 0
    %{state | messages_scroll: max(cur - delta, 0)}
  end

  @doc "Like scroll_messages/2 but for the details pane."
  @spec scroll_details(t(), integer()) :: t()
  def scroll_details(%__MODULE__{} = state, delta) when is_integer(delta) do
    cur = state.details_scroll || 0
    %{state | details_scroll: max(cur - delta, 0)}
  end

  @doc "Reset both panes back to auto-bottom (e.g. after Enter or End)."
  @spec reset_pane_scroll(t()) :: t()
  def reset_pane_scroll(%__MODULE__{} = state) do
    %{state | messages_scroll: nil, details_scroll: nil}
  end

  @doc "Jump the messages pane to the top (a very large offset; View clamps)."
  @spec scroll_messages_top(t()) :: t()
  def scroll_messages_top(%__MODULE__{} = state),
    do: %{state | messages_scroll: 1_000_000_000}

  @doc "Jump the details pane to the top."
  @spec scroll_details_top(t()) :: t()
  def scroll_details_top(%__MODULE__{} = state),
    do: %{state | details_scroll: 1_000_000_000}

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

  # ─ Input history (Up/Down navigation) ────────────────────────────────────

  @doc """
  Return the list of prior user-message contents in this session,
  newest-first. Used by the input's Up/Down history navigation.
  """
  @spec history(t()) :: [String.t()]
  def history(%__MODULE__{session: nil}), do: []

  def history(%__MODULE__{session: %{messages: msgs}}) when is_list(msgs) do
    msgs
    |> Enum.filter(fn
      %{role: :user} -> true
      _ -> false
    end)
    |> Enum.map(&extract_user_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reverse()
  end

  def history(_), do: []

  defp extract_user_text(%{content: c}) when is_binary(c), do: c

  defp extract_user_text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{type: :text, text: t} when is_binary(t) -> t
      %{text: t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_user_text(_), do: nil

  @doc """
  Step backward in input history (older). On the first call from a
  fresh state, snapshots the current `draft` (whatever the user had
  typed) so a later `history_next/2` can restore it.

  Returns `{state, replacement_text}` — the caller writes
  `replacement_text` into the textarea. Returns `{state, nil}` when
  there's no history to navigate.
  """
  @spec history_prev(t(), String.t()) :: {t(), String.t() | nil}
  def history_prev(%__MODULE__{} = state, draft) do
    items = history(state)

    case items do
      [] ->
        {state, nil}

      _ ->
        next_idx = (state.history_idx || -1) + 1
        next_idx = min(next_idx, length(items) - 1)
        new_draft = if is_nil(state.history_idx), do: draft, else: state.history_draft
        new_state = %{state | history_idx: next_idx, history_draft: new_draft}
        {new_state, Enum.at(items, next_idx)}
    end
  end

  @doc """
  Step forward in input history (newer). Past the newest entry
  restores the saved draft and exits navigation mode.

  Returns `{state, replacement_text}` — same contract as
  `history_prev/2`.
  """
  @spec history_next(t()) :: {t(), String.t() | nil}
  def history_next(%__MODULE__{history_idx: nil} = state), do: {state, nil}

  def history_next(%__MODULE__{history_idx: 0} = state) do
    # Off the end → restore the saved draft, exit navigation.
    draft = state.history_draft
    {%{state | history_idx: nil, history_draft: ""}, draft}
  end

  def history_next(%__MODULE__{history_idx: idx} = state) do
    items = history(state)
    new_idx = idx - 1
    {%{state | history_idx: new_idx}, Enum.at(items, new_idx)}
  end

  @doc "Cancel any in-progress history navigation (e.g. on submit or typing)."
  @spec reset_history_nav(t()) :: t()
  def reset_history_nav(%__MODULE__{} = state),
    do: %{state | history_idx: nil, history_draft: ""}

  @doc "Record whether crossterm mouse capture is currently on."
  @spec set_mouse_enabled(t(), boolean()) :: t()
  def set_mouse_enabled(%__MODULE__{} = state, enabled?) when is_boolean(enabled?),
    do: %{state | mouse_enabled: enabled?}

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

  # ─ Tool-block helpers ────────────────────────────────────────────────────

  # Detect a todo_write call and extract the todos list so the renderer
  # can show inline checkboxes instead of a generic tool block.
  defp parse_todos_from_call("todo_write", %{"todos" => todos}) when is_list(todos), do: todos
  defp parse_todos_from_call("todo_write", %{todos: todos}) when is_list(todos), do: todos
  defp parse_todos_from_call(_name, _args), do: nil

  # Cap how many output lines we keep on the block for the inline preview.
  # The full text is still routed to the details pane.
  @preview_max_lines 4

  defp preview_lines(""), do: {[], 0}

  defp preview_lines(content) when is_binary(content) do
    content
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> case do
      [""] -> {[], 0}
      lines -> {Enum.take(lines, @preview_max_lines), length(lines)}
    end
  end

  # Attach a :tool_ui payload to its matching block (looked up by
  # tool_call_id). No-op if the block isn't found.
  defp attach_tool_ui_to_block(state, %{tool_call_id: id, kind: kind, payload: payload}) do
    Map.update!(state, :tool_blocks, fn blocks ->
      case Map.get(blocks, id) do
        nil -> blocks
        block -> Map.put(blocks, id, Map.put(block, :ui, %{kind: kind, payload: payload}))
      end
    end)
  end

  defp attach_tool_ui_to_block(state, _), do: state

  defp maybe_get_field(map, key) when is_map(map), do: Map.get(map, key)
  defp maybe_get_field(_, _), do: nil

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

  defp truncate(text, limit) when is_binary(text) do
    case String.length(text) do
      n when n <= limit -> text
      _ -> String.slice(text, 0, limit) <> "…"
    end
  end

  defp truncate(other, limit), do: truncate(to_string(other), limit)
end
