defmodule ExAthena.Chat.Tui.StateTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Session
  alias ExAthena.Chat.Tui.State
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result

  describe "new/1" do
    test "wraps a Chat.Session with default UI fields" do
      session = Session.new(provider: :ollama, model: "qwen3:8b", mode: :react)
      state = State.new(session)

      assert state.session == session
      assert state.popup == nil
      assert state.events == []
      assert state.stream_buffer == ""
      assert state.loading? == false
      assert state.scroll_offset == 0
      assert state.input_ref == nil
      assert is_atom(state.prior_log_level)
      assert is_binary(state.footer)
    end
  end

  describe "append_event/2" do
    test "appends a row to events in order" do
      state =
        Session.new()
        |> State.new()
        |> State.append_event({:user, "hi"})
        |> State.append_event({:assistant, "hello"})

      assert state.events == [{:user, "hi"}, {:assistant, "hello"}]
    end
  end

  describe "append_loop_event/2" do
    test ":content with no in-progress assistant row appends to stream buffer only" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:content, "Hel"})
        |> State.append_loop_event({:content, "lo "})

      assert state.stream_buffer == "Hello "
      # Until flush_stream/1 runs, no assistant row is materialized.
      assert state.events == []
    end

    test ":tool_call records a :tool_block reference + a structured block by id" do
      tc = %ToolCall{id: "1", name: "Read", arguments: %{"path" => "lib/foo.ex"}}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})

      assert state.events == [{:tool_block, "1"}]

      assert %{id: "1", name: "Read", args: %{"path" => "lib/foo.ex"}, status: :pending} =
               Map.get(state.tool_blocks, "1")
    end

    test ":tool_result transitions the matching block to :success" do
      tc = %ToolCall{id: "1", name: "Read", arguments: %{"path" => "lib/foo.ex"}}
      tr = %ToolResult{tool_call_id: "1", content: "file contents", is_error: false}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})
        |> State.append_loop_event({:tool_result, tr})

      # Still only one event row — the same block reference.
      assert state.events == [{:tool_block, "1"}]
      block = Map.get(state.tool_blocks, "1")
      assert block.status == :success
      assert block.output_preview == ["file contents"]
    end

    test ":tool_result transitions the matching block to :error" do
      tc = %ToolCall{id: "1", name: "Bash", arguments: %{}}
      tr = %ToolResult{tool_call_id: "1", content: "boom", is_error: true}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})
        |> State.append_loop_event({:tool_result, tr})

      block = Map.get(state.tool_blocks, "1")
      assert block.status == :error
      assert block.output_preview == ["boom"]
    end

    test ":tool_result captures a multi-line preview + total" do
      tc = %ToolCall{id: "1", name: "Bash", arguments: %{}}
      content = "exit 0\nCHANGELOG.md\nLICENSE\nREADME.md\n_build/"
      tr = %ToolResult{tool_call_id: "1", content: content, is_error: false}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})
        |> State.append_loop_event({:tool_result, tr})

      block = Map.get(state.tool_blocks, "1")
      assert block.total_lines == 5
      # First 4 lines kept (preview_max_lines); the rest is captured as "remaining".
      assert length(block.output_preview) == 4
    end

    test "todo_write tool call extracts the todos list on the block" do
      todos = [
        %{"content" => "Step 1", "status" => "completed"},
        %{"content" => "Step 2", "status" => "in_progress"}
      ]

      tc = %ToolCall{id: "1", name: "todo_write", arguments: %{"todos" => todos}}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})

      block = Map.get(state.tool_blocks, "1")
      assert block.todos == todos
    end

    test ":tool_ui :diff payload attaches to the matching block" do
      tc = %ToolCall{id: "1", name: "edit", arguments: %{"path" => "foo.ex"}}

      ui = %{
        tool_call_id: "1",
        kind: :diff,
        payload: %{path: "foo.ex", before: "old", after: "new"}
      }

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})
        |> State.append_loop_event({:tool_ui, ui})

      block = Map.get(state.tool_blocks, "1")
      assert block.ui.kind == :diff
      assert block.ui.payload.path == "foo.ex"
    end

    test ":error adds a warn row" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:error, :rate_limited})

      assert [{:warning, line}] = state.events
      assert line =~ "rate_limited"
    end

    test ":compaction adds an info row with before/after counts" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:compaction, %{before: 12_000, after: 4_000}})

      assert [{:info, line}] = state.events
      assert line =~ "12000"
      assert line =~ "4000"
    end

    test ":subagent_spawn and :subagent_result add info rows" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:subagent_spawn, %{prompt: "do thing"}})
        |> State.append_loop_event({:subagent_result, %{text: "done"}})

      assert [{:info, spawn_line}, {:info, result_line}] = state.events
      assert spawn_line =~ "subagent"
      assert result_line =~ "subagent done"
    end

    test ":iteration, :usage, :tool_ui, :done events do not add a row" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:iteration, 3})
        |> State.append_loop_event({:usage, %{input_tokens: 10, output_tokens: 5}})
        |> State.append_loop_event({:tool_ui, %{}})
        |> State.append_loop_event({:done, :anything})

      assert state.events == []
    end

    test "unknown events are silently ignored" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:totally_made_up, :x})

      assert state.events == []
    end
  end

  describe "flush_stream/1" do
    test "appends buffered content as an :assistant row and clears the buffer" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:content, "Hello"})
        |> State.flush_stream()

      assert state.events == [{:assistant, "Hello"}]
      assert state.stream_buffer == ""
    end

    test "extends the most recent :assistant row when one already exists" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:content, "Hel"})
        |> State.flush_stream()
        |> State.append_loop_event({:content, "lo"})
        |> State.flush_stream()

      assert state.events == [{:assistant, "Hello"}]
    end

    test "is a no-op when the buffer is empty" do
      state = Session.new() |> State.new() |> State.flush_stream()
      assert state.events == []
      assert state.stream_buffer == ""
    end

    test "after a non-assistant row, the next content starts a fresh assistant row" do
      tc = %ToolCall{id: "1", name: "Read", arguments: %{}}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:content, "first"})
        |> State.flush_stream()
        |> State.append_loop_event({:tool_call, tc})
        |> State.append_loop_event({:content, "second"})
        |> State.flush_stream()

      assert [
               {:assistant, "first"},
               {:tool_block, _},
               {:assistant, "second"}
             ] = state.events
    end
  end

  describe "popups" do
    test "open_popup/2 sets popup state with index 0" do
      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:model, ~w(a b c)})

      assert state.popup == {:model, ["a", "b", "c"], 0}
    end

    test "open_popup/2 with an empty list still opens (caller decides)" do
      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:mode, []})

      assert state.popup == {:mode, [], 0}
    end

    test "move_popup_selection/2 wraps top-to-bottom and bottom-to-top" do
      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:model, ~w(a b c)})

      state_down = State.move_popup_selection(state, +1)
      assert state_down.popup == {:model, ~w(a b c), 1}

      state_up_from_top = State.move_popup_selection(state, -1)
      assert state_up_from_top.popup == {:model, ~w(a b c), 2}

      state_down_from_bottom =
        state
        |> State.move_popup_selection(+1)
        |> State.move_popup_selection(+1)
        |> State.move_popup_selection(+1)

      assert state_down_from_bottom.popup == {:model, ~w(a b c), 0}
    end

    test "move_popup_selection/2 is a no-op when popup is nil or empty" do
      base = Session.new() |> State.new()

      assert State.move_popup_selection(base, +1) == base

      empty = State.open_popup(base, {:mode, []})
      assert State.move_popup_selection(empty, +1) == empty
    end

    test "close_popup/1 clears popup" do
      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:model, ~w(a b)})
        |> State.close_popup()

      assert state.popup == nil
    end

    test "current_popup_selection/1 returns the selected element or nil" do
      base = Session.new() |> State.new()
      assert State.current_popup_selection(base) == nil

      with_popup = State.open_popup(base, {:model, ~w(a b c)})
      assert State.current_popup_selection(with_popup) == "a"

      moved = State.move_popup_selection(with_popup, +1)
      assert State.current_popup_selection(moved) == "b"

      empty = State.open_popup(base, {:mode, []})
      assert State.current_popup_selection(empty) == nil
    end
  end

  describe "set_loading/2 and apply_result/2" do
    test "set_loading/2 toggles the flag" do
      state = Session.new() |> State.new() |> State.set_loading(true)
      assert state.loading? == true
      assert State.set_loading(state, false).loading? == false
    end

    test "apply_result/2 updates the wrapped session via Session.apply_result/2" do
      session = Session.new() |> Session.append_user("hi")

      result = %Result{
        messages: session.messages,
        usage: %{input_tokens: 5, output_tokens: 3},
        cost_usd: 0.01,
        iterations: 1
      }

      state =
        session
        |> State.new()
        |> State.apply_result(result)

      assert state.session.usage == %{input_tokens: 5, output_tokens: 3}
      assert state.session.iteration == 1
      assert_in_delta state.session.cost_usd, 0.01, 0.0001
    end
  end

  describe "session passthroughs" do
    test "set_model/2 and set_mode/2 update the wrapped session" do
      state =
        Session.new()
        |> State.new()
        |> State.set_model("gemma2:9b")
        |> State.set_mode(:plan_and_solve)

      assert state.session.model == "gemma2:9b"
      assert state.session.mode == :plan_and_solve
    end

    test "clear_session/1 wipes messages and resets state.events" do
      state =
        Session.new()
        |> Session.append_user("hi")
        |> State.new()
        |> State.append_event({:user, "hi"})
        |> State.clear_session()

      assert state.session.messages == []
      assert state.events == []
    end
  end

  describe "input history" do
    setup do
      session =
        Session.new()
        |> Session.append_user("first prompt")
        |> Session.append_user("second prompt")
        |> Session.append_user("third prompt")

      {:ok, state: State.new(session)}
    end

    test "history/1 returns user messages newest-first", %{state: state} do
      assert State.history(state) == ["third prompt", "second prompt", "first prompt"]
    end

    test "history_prev/2 walks back through prior messages and snapshots draft",
         %{state: state} do
      assert {s1, "third prompt"} = State.history_prev(state, "in-progress draft")
      assert s1.history_idx == 0
      assert s1.history_draft == "in-progress draft"

      assert {s2, "second prompt"} = State.history_prev(s1, "")
      assert s2.history_idx == 1
      # Draft stays the same — not overwritten on subsequent presses.
      assert s2.history_draft == "in-progress draft"

      assert {s3, "first prompt"} = State.history_prev(s2, "")
      assert s3.history_idx == 2

      # At the oldest entry — further Up is a no-op (stays).
      assert {s4, "first prompt"} = State.history_prev(s3, "")
      assert s4.history_idx == 2
    end

    test "history_next/1 walks forward and restores the draft past the newest entry",
         %{state: state} do
      {s1, _} = State.history_prev(state, "my draft")
      {s2, _} = State.history_prev(s1, "")
      assert s2.history_idx == 1

      {s3, "third prompt"} = State.history_next(s2)
      assert s3.history_idx == 0

      # Past the newest → restore draft and exit nav mode.
      {s4, "my draft"} = State.history_next(s3)
      assert s4.history_idx == nil
      assert s4.history_draft == ""
    end

    test "history_next/1 with no active navigation is a no-op", %{state: state} do
      assert {^state, nil} = State.history_next(state)
    end

    test "history_prev/2 with empty history is a no-op" do
      state = Session.new() |> State.new()
      assert {^state, nil} = State.history_prev(state, "anything")
    end

    test "reset_history_nav/1 clears idx and draft", %{state: state} do
      {s1, _} = State.history_prev(state, "draft")
      state = State.reset_history_nav(s1)
      assert state.history_idx == nil
      assert state.history_draft == ""
    end
  end

  describe "pane scrolling" do
    test "scroll_messages/2 records rows-above-bottom" do
      state = Session.new() |> State.new()
      assert state.messages_scroll == nil

      # Scroll up by 10 → 10 rows above bottom.
      state = State.scroll_messages(state, -10)
      assert state.messages_scroll == 10

      # Another PgUp → 20 above.
      state = State.scroll_messages(state, -10)
      assert state.messages_scroll == 20

      # PgDn brings it back down.
      state = State.scroll_messages(state, +15)
      assert state.messages_scroll == 5

      # PgDn past the bottom clamps at 0.
      state = State.scroll_messages(state, +100)
      assert state.messages_scroll == 0
    end

    test "scroll_details/2 maintains its own offset" do
      state = Session.new() |> State.new() |> State.scroll_details(-7)
      assert state.details_scroll == 7
      assert state.messages_scroll == nil
    end

    test "reset_pane_scroll/1 clears both offsets back to nil" do
      state =
        Session.new()
        |> State.new()
        |> State.scroll_messages(-10)
        |> State.scroll_details(-5)
        |> State.reset_pane_scroll()

      assert state.messages_scroll == nil
      assert state.details_scroll == nil
    end

    test "scroll_*_top/1 pins to the top with a huge offset" do
      state = Session.new() |> State.new() |> State.scroll_messages_top()
      assert state.messages_scroll > 1_000_000

      state = State.scroll_details_top(state)
      assert state.details_scroll > 1_000_000
    end
  end

  describe "details tabs" do
    test "default details_tab is :timeline" do
      state = Session.new() |> State.new()
      assert state.details_tab == :timeline
    end

    test "cycle_details_tab/1 walks the tab list and wraps" do
      state = Session.new() |> State.new()
      assert State.cycle_details_tab(state).details_tab == :changes

      assert state
             |> State.cycle_details_tab()
             |> State.cycle_details_tab()
             |> Map.get(:details_tab) == :timeline
    end

    test "set_details_tab/2 jumps to a specific tab" do
      state = Session.new() |> State.new()
      assert State.set_details_tab(state, :changes).details_tab == :changes
      assert State.set_details_tab(state, :timeline).details_tab == :timeline
    end

    test "default diff_mode is :inline" do
      state = Session.new() |> State.new()
      assert state.diff_mode == :inline
    end

    test "set_diff_mode/2 sets explicit layout" do
      state = Session.new() |> State.new() |> State.set_diff_mode(:side_by_side)
      assert state.diff_mode == :side_by_side
      assert State.set_diff_mode(state, :inline).diff_mode == :inline
    end

    test "cycle_diff_mode/1 flips inline ↔ side_by_side" do
      state = Session.new() |> State.new()
      assert State.cycle_diff_mode(state).diff_mode == :side_by_side

      state = State.cycle_diff_mode(state)
      assert State.cycle_diff_mode(state).diff_mode == :inline
    end

    test "set_git_diff/2 stores the line list" do
      state =
        Session.new()
        |> State.new()
        |> State.set_git_diff(["diff --git a/foo b/foo", "+added"])

      assert state.git_diff_lines == ["diff --git a/foo b/foo", "+added"]
    end
  end

  describe "autocomplete_for/2" do
    test "is nil for an empty / non-slash input" do
      assert State.autocomplete_for("") == nil
      assert State.autocomplete_for("hello") == nil
    end

    test "opens with every verb on bare /" do
      assert %{items: items, idx: 0} = State.autocomplete_for("/")
      # All canonical verbs.
      assert "/help" in items
      assert "/cd" in items
      assert "/details" in items
    end

    test "filters to verbs starting with the typed prefix" do
      assert %{items: ["/cd"], idx: 0} = State.autocomplete_for("/cd")
      assert %{items: items, idx: 0} = State.autocomplete_for("/c")
      # /cd and /clear both start with /c.
      assert "/cd" in items
      assert "/clear" in items
      refute "/help" in items
    end

    test "closes when whitespace appears in the verb" do
      assert State.autocomplete_for("/cd ~/test") == nil
      assert State.autocomplete_for("/help ") == nil
    end

    test "preserves the selected verb across keystrokes when still in filtered list" do
      prior = %{items: ["/cd", "/clear"], idx: 1}
      # Narrow /c → /cl — /clear should remain selected (still in the list).
      assert %{items: ["/clear"], idx: 0} = State.autocomplete_for("/cl", prior)
    end
  end

  describe "parse_stream_chunk/2 — streaming <think> parser" do
    @start %{mode: :outside, pending: "", close_tag: nil}

    test "passes plain text through unchanged" do
      assert {%{mode: :outside, pending: "", close_tag: nil}, "Hello world", ""} =
               State.parse_stream_chunk(@start, "Hello world")
    end

    test "splits a complete <think>...</think> block in one chunk" do
      assert {parser, "Answer", "reasoning"} =
               State.parse_stream_chunk(@start, "<think>reasoning</think>Answer")

      assert parser.mode == :outside
    end

    test "handles a tag split across two deltas" do
      {p1, c1, t1} = State.parse_stream_chunk(@start, "Hello <thi")
      assert c1 == "Hello "
      assert t1 == ""
      # Partial open tag held in pending
      assert p1.pending == "<thi"
      assert p1.mode == :outside

      {p2, c2, t2} = State.parse_stream_chunk(p1, "nk>let me think</think>foo")
      # The full block resolves across the boundary
      assert c2 == "foo"
      assert t2 == "let me think"
      assert p2.mode == :outside
      assert p2.pending == ""
    end

    test "handles a close tag split across deltas" do
      {p1, c1, t1} = State.parse_stream_chunk(@start, "<think>thinking part 1")
      assert c1 == ""
      assert t1 == "thinking part 1"
      assert p1.mode == :inside

      {p2, c2, t2} = State.parse_stream_chunk(p1, " part 2</thi")
      assert c2 == ""
      assert t2 == " part 2"
      assert p2.mode == :inside
      assert p2.pending == "</thi"

      {p3, c3, t3} = State.parse_stream_chunk(p2, "nk>answer")
      assert c3 == "answer"
      assert t3 == ""
      assert p3.mode == :outside
    end

    test "supports <thinking>...</thinking> as well" do
      assert {_, "ok", "deep"} =
               State.parse_stream_chunk(@start, "<thinking>deep</thinking>ok")
    end

    test "handles multiple blocks in one chunk" do
      {_p, content, thinking} =
        State.parse_stream_chunk(@start, "<think>a</think>b<think>c</think>d")

      assert content == "bd"
      assert thinking == "ac"
    end
  end

  describe "append_loop_event/2 — streaming events" do
    test ":text_delta routes content to stream_buffer and <think> body to thinking buffer" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event(%ExAthena.Streaming.Event{
          type: :text_delta,
          data: "<think>plan</think>Hello"
        })

      assert state.stream_buffer == "Hello"
      assert state.details_stream_buffer == "Hello"
      assert state.details_thinking_buffer == "plan"
      assert state.streamed_this_turn? == true
    end

    test ":thinking_delta routes directly to thinking buffer" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event(%ExAthena.Streaming.Event{type: :thinking_delta, data: "abc"})

      assert state.details_thinking_buffer == "abc"
      assert state.streamed_this_turn? == true
    end

    test "end-of-turn {:content, text} is suppressed when streaming already happened" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event(%ExAthena.Streaming.Event{type: :text_delta, data: "Hi"})
        |> State.append_loop_event({:content, "Hi"})

      # Buffer wasn't doubled.
      assert state.stream_buffer == "Hi"
    end

    test "reset_stream_state/1 clears the parser + dedup flag" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event(%ExAthena.Streaming.Event{type: :text_delta, data: "<thi"})

      assert state.stream_parser.pending == "<thi"
      assert state.streamed_this_turn? == true

      state = State.reset_stream_state(state)
      assert state.stream_parser.pending == ""
      assert state.streamed_this_turn? == false
    end
  end

  describe "split_thinking_blocks/1" do
    test "extracts a single <think>…</think> block" do
      assert {"my reasoning", "the answer"} =
               State.split_thinking_blocks("<think>my reasoning</think>the answer")
    end

    test "joins multiple blocks with newlines" do
      assert {"a\nb", "rest"} =
               State.split_thinking_blocks("<think>a</think> <think>b</think> rest")
    end

    test "supports <thinking> as well as <think>" do
      assert {"reasoning", "answer"} =
               State.split_thinking_blocks("<thinking>reasoning</thinking>answer")
    end

    test "spans newlines inside the block" do
      input = "<think>line 1\nline 2</think>final"
      assert {"line 1\nline 2", "final"} = State.split_thinking_blocks(input)
    end

    test "is a passthrough when no tags are present" do
      assert {"", "plain answer"} = State.split_thinking_blocks("plain answer")
    end
  end

  describe ":content with <think> tags" do
    test "routes inside-tag content to thinking buffer and the rest to stream buffer" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:content, "<think>plan it</think>Hello there"})

      assert state.details_thinking_buffer == "plan it"
      assert state.stream_buffer == "Hello there"
      assert state.details_stream_buffer == "Hello there"
    end
  end

  describe "provider popup" do
    test "open_popup/2 opens a :provider popup with {name, display_name} tuples" do
      items = [{"ollama", "ollama"}, {"my-openai", "My OpenAI"}]

      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:provider, items})

      assert state.popup == {:provider, items, 0}
    end

    test "current_popup_selection/1 returns the name (not display_name) from a provider tuple" do
      items = [{"ollama", "Ollama"}, {"my-openai", "My OpenAI"}]

      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:provider, items})

      assert State.current_popup_selection(state) == "ollama"

      moved = State.move_popup_selection(state, +1)
      assert State.current_popup_selection(moved) == "my-openai"
    end

    test "current_popup_selection/1 returns nil for empty provider popup" do
      state =
        Session.new()
        |> State.new()
        |> State.open_popup({:provider, []})

      assert State.current_popup_selection(state) == nil
    end
  end

  describe "set_provider/2" do
    test "updates the session provider" do
      state =
        Session.new()
        |> State.new()
        |> State.set_provider(:openai)

      assert state.session.provider == :openai
    end
  end

  describe "set_api_key/2" do
    test "sets the api_key and clears api_key_pending" do
      state =
        Session.new()
        |> State.new()
        |> Map.put(:api_key_pending, true)
        |> State.set_api_key("sk-test-key")

      assert state.api_key == "sk-test-key"
      assert state.api_key_pending == false
    end

    test "api_key and api_key_pending default to nil/false in new state" do
      state = Session.new() |> State.new()
      assert state.api_key == nil
      assert state.api_key_pending == false
      assert state.pending_message == nil
    end
  end

  describe "details pane" do
    test ":tool_call appends a header + full pretty-printed args to details" do
      tc = %ToolCall{id: "1", name: "Read", arguments: %{"path" => "lib/foo.ex"}}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})

      assert [{:detail_header, header} | rows] = state.details
      assert header =~ "Read"
      # The pretty-printed JSON spans multiple rows; each row is one entry.
      assert Enum.any?(rows, fn {kind, line} -> kind == :tool_call and line =~ "path" end)
    end

    test ":tool_result appends the FULL content (not summarized) to details" do
      tr = %ToolResult{
        tool_call_id: "1",
        content: "line one\nline two\nline three",
        is_error: false
      }

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_result, tr})

      texts = for {_, text} <- state.details, do: text
      assert "line one" in texts
      assert "line two" in texts
      assert "line three" in texts
    end

    test ":iteration adds a header row to details but no row to events" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:iteration, 7})

      assert state.events == []
      assert [{:detail_header, "iteration 7"}] = state.details
    end

    test ":thinking deltas accumulate and flush into a thinking row in details" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:thinking, "let me "})
        |> State.append_loop_event({:thinking, "think…"})

      # Until flush_stream/1, the buffer holds the text.
      assert state.details_thinking_buffer == "let me think…"
      assert state.details == []

      state = State.flush_stream(state)
      assert state.details_thinking_buffer == ""
      assert [{:thinking, "let me think…"}] = state.details
    end

    test "clear_session/1 also resets details state" do
      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:iteration, 1})
        |> State.append_loop_event({:thinking, "hmm"})
        |> State.clear_session()

      assert state.details == []
      assert state.details_stream_buffer == ""
      assert state.details_thinking_buffer == ""
      assert state.details_scroll_offset == 0
    end
  end
end
