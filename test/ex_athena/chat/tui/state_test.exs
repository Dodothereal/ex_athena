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

    test ":tool_call adds a one-line arrow row" do
      tc = %ToolCall{id: "1", name: "Read", arguments: %{"path" => "lib/foo.ex"}}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_call, tc})

      assert [{:tool_call, line}] = state.events
      assert line =~ "→ Read"
      assert line =~ "path"
      assert line =~ "lib/foo.ex"
    end

    test ":tool_result success uses :tool_result kind" do
      tr = %ToolResult{tool_call_id: "1", content: "file contents", is_error: false}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_result, tr})

      assert [{:tool_result, line}] = state.events
      assert line =~ "← file contents"
    end

    test ":tool_result error uses :tool_result_error kind" do
      tr = %ToolResult{tool_call_id: "1", content: "boom", is_error: true}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_result, tr})

      assert [{:tool_result_error, line}] = state.events
      assert line =~ "boom"
    end

    test ":tool_result with multi-line content collapses into a count" do
      content = "exit 0\nCHANGELOG.md\nLICENSE\nREADME.md\n_build/"
      tr = %ToolResult{tool_call_id: "1", content: content, is_error: false}

      state =
        Session.new()
        |> State.new()
        |> State.append_loop_event({:tool_result, tr})

      assert [{:tool_result, line}] = state.events
      assert line =~ "← exit 0"
      assert line =~ "5 lines"
      refute line =~ "CHANGELOG.md"
      assert length(String.split(line, "\n")) == 1
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
               {:tool_call, _},
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
end
