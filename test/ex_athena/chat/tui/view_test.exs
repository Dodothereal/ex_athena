defmodule ExAthena.Chat.Tui.ViewTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Session
  alias ExAthena.Chat.Tui.{State, View}
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List, Paragraph, Popup, Textarea, Throbber, WidgetList}

  describe "status_line/1" do
    test "renders model · mode · iter · tokens · cost separated by middle-dot" do
      session = %Session{
        provider: :ollama,
        model: "llama3.1",
        mode: :react,
        iteration: 3,
        usage: %{input_tokens: 120, output_tokens: 45},
        cost_usd: 0.0042
      }

      text = View.status_line(session)

      assert is_binary(text)
      assert text =~ "llama3.1"
      assert text =~ "react"
      assert text =~ "iter=3"
      assert text =~ "120/45 tok"
      assert text =~ "$0.0042"
      assert text =~ " · "
    end
  end

  describe "build_frame/2 — layout structure" do
    setup do
      session = Session.new(provider: :ollama, model: "llama3.1", mode: :react)
      state = State.new(session)
      frame = %Frame{width: 80, height: 24}
      {:ok, state: state, frame: frame}
    end

    test "returns at least four widgets that tile the frame vertically (header, messages, input, footer)",
         %{state: state, frame: frame} do
      widgets = View.build_frame(state, frame)

      # Every entry is a {widget, rect} tuple.
      assert is_list(widgets)
      assert length(widgets) >= 4

      rects = Enum.map(widgets, fn {_w, rect} -> rect end)

      # All rects stay within the frame horizontally.
      Enum.each(rects, fn r ->
        assert r.x >= 0
        assert r.x + r.width <= frame.width
        assert r.y >= 0
        assert r.y + r.height <= frame.height
      end)

      # Find the four base rects by y-coordinate / height heuristics.
      sorted = Enum.sort_by(rects, & &1.y)

      header = Enum.find(sorted, &(&1.y == 0 and &1.height == 1))
      footer = Enum.find(sorted, &(&1.y + &1.height == frame.height))

      assert header, "expected a 1-row header at y=0"
      assert footer, "expected a footer that ends at the frame's bottom"
    end

    test "header carries the status line", %{state: state, frame: frame} do
      widgets = View.build_frame(state, frame)

      header =
        Enum.find(widgets, fn
          {%Paragraph{}, %Rect{y: 0, height: 1}} -> true
          _ -> false
        end)

      assert {%Paragraph{text: text}, _} = header
      assert text =~ "llama3.1"
      assert text =~ "react"
    end

    test "footer is a Paragraph with shortcut hints (no popup)",
         %{state: state, frame: frame} do
      widgets = View.build_frame(state, frame)

      {_paragraph, _rect} =
        footer =
        Enum.find(widgets, fn
          {%Paragraph{text: text}, %Rect{y: y, height: 1}} ->
            y + 1 == frame.height and text =~ "Enter" and text =~ "Ctrl+C"

          _ ->
            false
        end)

      assert footer
    end

    test "input area renders a Textarea inside the input rect",
         %{state: state, frame: frame} do
      widgets = View.build_frame(state, frame)

      assert Enum.any?(widgets, fn
               {%Textarea{}, %Rect{}} -> true
               _ -> false
             end)
    end

    test "messages area renders a WidgetList with empty items when there are no events",
         %{state: state, frame: frame} do
      widgets = View.build_frame(state, frame)

      assert Enum.any?(widgets, fn
               {%WidgetList{items: []}, %Rect{}} -> true
               _ -> false
             end)
    end
  end

  describe "build_frame/2 — event row rendering" do
    setup do
      session = Session.new(provider: :ollama, model: "qwen3:8b", mode: :react)
      frame = %Frame{width: 80, height: 24}
      {:ok, session: session, frame: frame}
    end

    test "user rows are prefixed with 'me ▸ '", %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.append_event({:user, "refactor foo"})

      widgets = View.build_frame(state, frame)
      list = find_widget_list(widgets)

      assert [{%Paragraph{text: text}, 1}] = list.items
      assert text == "me ▸ refactor foo"
    end

    test "assistant rows are prefixed with '<model> ▸ '",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.append_event({:assistant, "Hello world"})

      widgets = View.build_frame(state, frame)
      list = find_widget_list(widgets)

      assert [{%Paragraph{text: text}, 1}] = list.items
      assert text == "qwen3:8b ▸ Hello world"
    end

    test "non-chat rows (tool_call, tool_result, info, warning) render text verbatim",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.append_event({:tool_call, "→ Read(path: lib/foo.ex)"})
        |> State.append_event({:tool_result, "← 142 lines"})
        |> State.append_event({:info, "⤵ compacted 12000→4000 tokens"})
        |> State.append_event({:warning, "warn: rate_limited"})
        |> State.append_event({:tool_result_error, "← boom"})

      widgets = View.build_frame(state, frame)
      list = find_widget_list(widgets)
      texts = Enum.map(list.items, fn {%Paragraph{text: t}, _} -> t end)

      assert "→ Read(path: lib/foo.ex)" in texts
      assert "← 142 lines" in texts
      assert "⤵ compacted 12000→4000 tokens" in texts
      assert "warn: rate_limited" in texts
      assert "← boom" in texts
    end

    test "loading? appends a Throbber to the messages list",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.set_loading(true)

      widgets = View.build_frame(state, frame)
      list = find_widget_list(widgets)

      assert Enum.any?(list.items, fn
               {%Throbber{}, _} -> true
               _ -> false
             end)
    end

    test "scroll_offset is forwarded to the WidgetList",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> Map.put(:scroll_offset, 7)

      widgets = View.build_frame(state, frame)
      list = find_widget_list(widgets)

      assert list.scroll_offset == 7
    end
  end

  describe "build_frame/2 — popup overlay" do
    setup do
      session = Session.new(provider: :ollama, model: "qwen3:8b", mode: :react)
      frame = %Frame{width: 80, height: 24}
      {:ok, session: session, frame: frame}
    end

    test "when state.popup is {:model, items, idx}, a Popup widget is overlaid",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.open_popup({:model, ~w(qwen3:8b llama3.1 gemma2:9b)})
        |> State.move_popup_selection(+1)

      widgets = View.build_frame(state, frame)

      popup =
        Enum.find(widgets, fn
          {%Popup{}, _} -> true
          _ -> false
        end)

      assert popup, "expected a Popup widget when state.popup is set"
      {%Popup{content: content, block: block}, _rect} = popup
      assert %List{items: items, selected: 1} = content
      assert "qwen3:8b" in items
      assert "llama3.1" in items
      assert "gemma2:9b" in items
      assert block && block.title =~ "model"
    end

    test "when state.popup is {:mode, ...}, the popup lists modes by inspect/1",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.open_popup({:mode, [:react, :plan_and_solve, :reflexion]})

      widgets = View.build_frame(state, frame)

      assert {%Popup{content: %List{items: items, selected: 0}, block: %Block{title: title}}, _} =
               Enum.find(widgets, fn
                 {%Popup{}, _} -> true
                 _ -> false
               end)

      assert ":react" in items
      assert ":plan_and_solve" in items
      assert ":reflexion" in items
      assert title =~ "mode"
    end

    test "no Popup widget when state.popup is nil", %{session: session, frame: frame} do
      state = session |> State.new()
      widgets = View.build_frame(state, frame)

      refute Enum.any?(widgets, fn
               {%Popup{}, _} -> true
               _ -> false
             end)
    end

    test "footer hints reflect popup state (↑↓ Enter Esc)",
         %{session: session, frame: frame} do
      state =
        session
        |> State.new()
        |> State.open_popup({:mode, [:react, :plan_and_solve]})

      widgets = View.build_frame(state, frame)
      {%Paragraph{text: text}, _} = find_footer(widgets, frame)

      assert text =~ "↑" or text =~ "Up"
      assert text =~ "Enter"
      assert text =~ "Esc"
    end
  end

  describe "build_frame/2 — CellSession snapshot integration" do
    test "the widget list renders without panicking and the header text reaches the buffer" do
      session = Session.new(provider: :ollama, model: "llama3.1", mode: :react)
      input_ref = ExRatatui.textarea_new()

      state =
        session
        |> State.new()
        |> Map.put(:input_ref, input_ref)
        |> State.append_event({:user, "hello"})

      frame = %Frame{width: 80, height: 24}

      session_ref = ExRatatui.CellSession.new(80, 24)
      :ok = ExRatatui.CellSession.draw(session_ref, View.build_frame(state, frame))
      snapshot = ExRatatui.CellSession.take_cells(session_ref)
      :ok = ExRatatui.CellSession.close(session_ref)

      text = snapshot_to_text(snapshot)
      assert text =~ "llama3.1"
      assert text =~ "hello"
    end
  end

  defp find_widget_list(widgets) do
    {list, _rect} =
      Enum.find(widgets, fn
        {%WidgetList{}, _} -> true
        _ -> false
      end)

    list
  end

  defp find_footer(widgets, frame) do
    Enum.find(widgets, fn
      {%Paragraph{}, %Rect{y: y, height: 1}} -> y + 1 == frame.height
      _ -> false
    end)
  end

  # `take_cells/1` returns a `Snapshot{cells: [...], width:, height:}`.
  # Each cell carries a `:symbol`. Flatten into one big string for grep-style
  # assertions in tests.
  defp snapshot_to_text(%{cells: cells, width: w}) do
    cells
    |> Enum.chunk_every(w)
    |> Enum.map(fn row -> row |> Enum.map(& &1.symbol) |> Enum.join() end)
    |> Enum.join("\n")
  end
end
