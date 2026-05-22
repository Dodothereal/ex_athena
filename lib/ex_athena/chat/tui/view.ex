defmodule ExAthena.Chat.Tui.View do
  @moduledoc """
  Pure view function for `ExAthena.Chat.Tui`. Turns a `%State{}` into the
  list of `{widget, %Rect{}}` tuples the ex_ratatui runtime needs.

  Layout (top-to-bottom):

    1. Header (1 row) — `provider · model · mode · iter=N · in/out tok · $cost`.
    2. Body (flex) — split horizontally 50/50 into:
         * Left  — `messages` WidgetList (one `{Paragraph, 1}` per event row).
           If `state.loading? == true`, a `Throbber` is appended.
         * Right — `details` WidgetList: full args, full tool results, thinking,
           tool UI payloads, and every loop event. Wrapped in a titled `Block`
           with a left border.
    3. Input (3 rows) — `Textarea` bound to `state.input_ref` inside a
       titled `Block`.
    4. Footer (1 row) — shortcut hints (changes when a popup is open).

  When `state.popup != nil`, a `Popup` widget overlays the messages
  rect with a centered `List`.
  """

  alias ExAthena.Chat.{Commands, Session, Tui.State}
  alias ExRatatui.Frame
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Clear, List, Paragraph, Popup, Textarea, Throbber, WidgetList}

  @input_height 3
  @footer_height 1

  @input_block %Block{
    title: " me ▸ ",
    borders: [:all],
    border_type: :rounded
  }

  @doc """
  Build the per-frame widget list for the given state and frame.
  """
  @spec build_frame(State.t(), Frame.t()) :: [{struct(), Rect.t()}]
  def build_frame(%State{} = state, %Frame{width: w, height: h}) do
    area = %Rect{x: 0, y: 0, width: w, height: h}

    [header_rect, body_rect, input_rect, footer_rect] =
      Layout.split(area, :vertical, [
        {:length, 1},
        {:min, 0},
        {:length, @input_height},
        {:length, @footer_height}
      ])

    {messages_rect, details_rect} = split_body(body_rect, state)

    widgets =
      [
        {header(state), header_rect},
        {messages(state, messages_rect.width, messages_rect.height), messages_rect},
        {input(state), input_rect},
        {footer(state), footer_rect}
      ] ++ details_widget(state, details_rect) ++ autocomplete_widget(state, input_rect)

    case popup(state, messages_rect) do
      nil -> widgets
      popup_tuple -> widgets ++ [popup_tuple]
    end
  end

  defp split_body(body_rect, %State{show_details: false}), do: {body_rect, nil}

  defp split_body(body_rect, _state) do
    [m, d] = Layout.split(body_rect, :horizontal, [{:percentage, 50}, {:percentage, 50}])
    {m, d}
  end

  defp details_widget(_state, nil), do: []

  defp details_widget(state, details_rect) do
    [tabs_rect, content_rect] =
      Layout.split(details_rect, :vertical, [{:length, 1}, {:min, 0}])

    # The content Block draws borders on all four sides, so the interior
    # is two cells narrower AND two cells shorter than the outer rect.
    inner_w = max(content_rect.width - 2, 1)
    inner_h = max(content_rect.height - 2, 1)

    content_widget =
      case state.details_tab do
        :timeline -> details(state, inner_w, inner_h)
        :changes -> changes(state, inner_w, inner_h)
      end

    [
      {details_tabs_widget(state), tabs_rect},
      {content_widget, content_rect}
    ]
  end

  defp details_tabs_widget(%State{details_tab: tab} = state) do
    tabs = State.details_tabs()
    titles = Enum.map(tabs, &tab_title(&1, state))
    selected = Enum.find_index(tabs, &(&1 == tab)) || 0

    %ExRatatui.Widgets.Tabs{
      titles: titles,
      selected: selected,
      style: %Style{fg: :dark_gray},
      highlight_style: %Style{fg: :light_blue, modifiers: [:bold]},
      divider: " │ "
    }
  end

  defp tab_title(:timeline, _state), do: " Timeline "

  defp tab_title(:changes, %State{git_diff_lines: lines}) do
    case changed_files_count(lines) do
      0 -> " Changes "
      n -> " Changes (#{n} file#{if n == 1, do: "", else: "s"}) "
    end
  end

  defp tab_title(other, _state), do: " #{other} "

  # Quick count of `diff --git` headers — one per modified file.
  defp changed_files_count(lines) do
    Enum.count(lines, &String.starts_with?(&1, "diff --git "))
  end

  # ─ Autocomplete (slash command suggestions) ───────────────────────────────

  @ac_max_rows 10
  @ac_block %Block{
    title: " commands · Tab to accept · Esc to close ",
    borders: [:all],
    border_type: :rounded,
    border_style: %Style{fg: :light_blue}
  }

  defp autocomplete_widget(%State{autocomplete: nil}, _input_rect), do: []

  defp autocomplete_widget(%State{autocomplete: %{items: items, idx: idx}}, input_rect) do
    descs = Commands.descriptions()
    label_width = items |> Enum.map(&String.length/1) |> Enum.max(fn -> 8 end)

    labels =
      Enum.map(items, fn cmd ->
        desc = Map.get(descs, cmd, "")
        pad = max(0, label_width - String.length(cmd))
        cmd <> String.duplicate(" ", pad) <> "  " <> desc
      end)

    body_height = min(length(labels), @ac_max_rows)
    # +2 for the block's top/bottom borders.
    height = body_height + 2

    inner_width = labels |> Enum.map(&String.length/1) |> Enum.max(fn -> 20 end)
    width = min(inner_width + 4, input_rect.width)

    rect = %Rect{
      x: input_rect.x,
      y: max(input_rect.y - height, 0),
      width: width,
      height: height
    }

    list = %List{
      items: labels,
      selected: idx,
      block: @ac_block,
      highlight_style: %Style{fg: :black, bg: :light_blue, modifiers: [:bold]},
      highlight_symbol: "▸ "
    }

    # Clear the underlying messages area first so the popup is opaque.
    [{%Clear{}, rect}, {list, rect}]
  end

  @doc "Build the header status string from a session."
  @spec status_line(Session.t()) :: String.t()
  def status_line(%Session{} = s) do
    cwd = s.cwd || effective_cwd()

    IO.iodata_to_binary([
      to_string(s.model),
      " · ",
      inspect(s.mode),
      " · iter=",
      Integer.to_string(s.iteration),
      " · ",
      Integer.to_string(Map.get(s.usage, :input_tokens, 0)),
      "/",
      Integer.to_string(Map.get(s.usage, :output_tokens, 0)),
      " tok · $",
      :erlang.float_to_binary(s.cost_usd / 1.0, decimals: 4),
      " · cwd=",
      Path.basename(cwd)
    ])
  end

  defp effective_cwd do
    case File.cwd() do
      {:ok, path} -> path
      _ -> "?"
    end
  end

  defp header(%State{session: session}) do
    %Paragraph{
      text: status_line(session),
      style: %Style{fg: :light_blue},
      alignment: :left
    }
  end

  defp messages(
         %State{
           events: events,
           loading?: loading?,
           session: session,
           messages_scroll: above_bottom
         },
         width,
         height
       ) do
    items =
      events
      |> Enum.map(&row_widget(&1, session.model, width))
      |> append_throbber(loading?)

    %WidgetList{items: items, scroll_offset: scroll_offset(items, height, above_bottom)}
  end

  @details_block %Block{
    title: " details ",
    borders: [:left, :top, :bottom, :right],
    border_type: :rounded,
    border_style: %Style{fg: :dark_gray}
  }

  defp details(%State{details: details, details_scroll: above_bottom}, width, height) do
    items = Enum.map(details, &detail_row_widget(&1, width))

    %WidgetList{
      items: items,
      scroll_offset: scroll_offset(items, height, above_bottom),
      block: @details_block
    }
  end

  @changes_block %Block{
    title: " changes · git diff HEAD ",
    borders: [:left, :top, :bottom, :right],
    border_type: :rounded,
    border_style: %Style{fg: :dark_gray}
  }

  defp changes(%State{git_diff_lines: []}, _width, _height) do
    %WidgetList{
      items: [
        {%Paragraph{
           text: "Fetching `git diff` … (run /diff to refresh)",
           style: %Style{fg: :dark_gray}
         }, 1}
      ],
      block: @changes_block
    }
  end

  defp changes(%State{git_diff_lines: lines, details_scroll: above_bottom}, width, height) do
    items = Enum.map(lines, &diff_row_widget(&1, width))

    %WidgetList{
      items: items,
      scroll_offset: scroll_offset(items, height, above_bottom),
      block: @changes_block
    }
  end

  # Color each diff line by its first character: `+` green, `-` red,
  # `@@` (hunk header) cyan, `diff/index/---/+++` (file headers) yellow,
  # everything else dim. Each line is a height-1 wrapped Paragraph.
  defp diff_row_widget(line, width) do
    style = diff_line_style(line)
    {%Paragraph{text: line, style: style, wrap: true}, wrapped_height(line, width)}
  end

  defp diff_line_style("+++ " <> _), do: %Style{fg: :light_yellow, modifiers: [:bold]}
  defp diff_line_style("--- " <> _), do: %Style{fg: :light_yellow, modifiers: [:bold]}
  defp diff_line_style("diff " <> _), do: %Style{fg: :light_yellow, modifiers: [:bold]}
  defp diff_line_style("index " <> _), do: %Style{fg: :dark_gray}
  defp diff_line_style("@@" <> _), do: %Style{fg: :cyan}
  defp diff_line_style("+" <> _), do: %Style{fg: :green}
  defp diff_line_style("-" <> _), do: %Style{fg: :red}
  defp diff_line_style("(no changes vs HEAD)"), do: %Style{fg: :dark_gray, modifiers: [:italic]}
  defp diff_line_style("git diff failed" <> _), do: %Style{fg: :red, modifiers: [:bold]}
  defp diff_line_style("git diff crashed" <> _), do: %Style{fg: :red, modifiers: [:bold]}
  defp diff_line_style("`git` executable" <> _), do: %Style{fg: :red, modifiers: [:bold]}
  defp diff_line_style("cwd: " <> _), do: %Style{fg: :dark_gray, modifiers: [:italic]}
  defp diff_line_style(_), do: %Style{fg: :dark_gray}

  # Compute a scroll_offset for a WidgetList. `above_bottom` is the user's
  # manual scroll position (in rows above the natural bottom); nil = "at
  # the bottom" (auto-pin to newest content). When the user has scrolled
  # up, we step back from the auto-bottom by `above_bottom` rows, clamped
  # to [0, max_offset] so it never escapes the content.
  defp scroll_offset(items, height, above_bottom)
       when is_integer(height) and height > 0 do
    total = items |> Enum.map(fn {_w, h} -> h end) |> Enum.sum()
    auto = max(total - height, 0)

    case above_bottom do
      nil -> auto
      n when is_integer(n) -> auto |> Kernel.-(n) |> max(0)
    end
  end

  defp scroll_offset(_items, _height, _above_bottom), do: 0

  # Estimate the number of rows a string occupies once it's wrapped at
  # `width` columns. Counts each explicit `\n` as a line break and uses
  # `String.length/1` to approximate display columns (good enough for
  # ASCII / European text; emoji and CJK may be off by one). The Paragraph
  # widget does the actual wrapping; this just sizes the row in the
  # surrounding WidgetList so wrapped content isn't clipped.
  defp wrapped_height(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      case String.length(line) do
        0 -> 1
        n -> div(n - 1, width) + 1
      end
    end)
    |> Enum.sum()
    |> max(1)
  end

  defp wrapped_height(_text, _width), do: 1

  defp detail_row_widget({:detail_header, text}, width) do
    {%Paragraph{
       text: text,
       style: %Style{fg: :light_yellow, modifiers: [:bold]},
       wrap: true
     }, wrapped_height(text, width)}
  end

  defp detail_row_widget({:thinking, text}, width) do
    {%Paragraph{
       text: text,
       style: %Style{fg: :magenta, modifiers: [:italic]},
       wrap: true
     }, wrapped_height(text, width)}
  end

  defp detail_row_widget({:assistant, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :white}, wrap: true}, wrapped_height(text, width)}
  end

  defp detail_row_widget({:tool_call, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :cyan}, wrap: true}, wrapped_height(text, width)}
  end

  defp detail_row_widget({:tool_result, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true},
     wrapped_height(text, width)}
  end

  defp detail_row_widget({:tool_result_error, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :red}, wrap: true}, wrapped_height(text, width)}
  end

  defp detail_row_widget({:error, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :red, modifiers: [:bold]}, wrap: true},
     wrapped_height(text, width)}
  end

  defp detail_row_widget({:info, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true},
     wrapped_height(text, width)}
  end

  defp detail_row_widget({_kind, text}, width) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true},
     wrapped_height(text, width)}
  end

  defp row_widget({:user, text}, _model, width) do
    full = "me ▸ " <> text

    {%Paragraph{text: full, style: %Style{fg: :green, modifiers: [:bold]}, wrap: true},
     wrapped_height(full, width)}
  end

  defp row_widget({:assistant, text}, model, width) do
    full = model <> " ▸ " <> text

    {%Paragraph{text: full, style: %Style{fg: :cyan, modifiers: [:bold]}, wrap: true},
     wrapped_height(full, width)}
  end

  defp row_widget({:tool_call, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :cyan}, wrap: true}, wrapped_height(text, width)}
  end

  defp row_widget({:tool_result, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true},
     wrapped_height(text, width)}
  end

  defp row_widget({:tool_result_error, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :red}, wrap: true}, wrapped_height(text, width)}
  end

  defp row_widget({:warning, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :yellow}, wrap: true}, wrapped_height(text, width)}
  end

  defp row_widget({:error, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :red, modifiers: [:bold]}, wrap: true},
     wrapped_height(text, width)}
  end

  defp row_widget({:info, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true},
     wrapped_height(text, width)}
  end

  defp row_widget({:status, text}, _model, width) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true},
     wrapped_height(text, width)}
  end

  defp append_throbber(items, false), do: items

  defp append_throbber(items, true) do
    items ++
      [
        {%Throbber{
           label: " thinking…",
           throbber_set: :braille,
           style: %Style{fg: :dark_gray}
         }, 1}
      ]
  end

  defp input(%State{input_ref: ref}) do
    %Textarea{
      state: ref,
      placeholder: "Type a message and press Enter to send. /help for commands.",
      placeholder_style: %Style{fg: :dark_gray},
      block: @input_block
    }
  end

  defp footer(%State{popup: nil}) do
    %Paragraph{
      text: "Enter: send  Ctrl+C: quit  /help",
      style: %Style{fg: :dark_gray}
    }
  end

  defp footer(%State{popup: _}) do
    %Paragraph{
      text: "↑↓ navigate  Enter select  Esc cancel",
      style: %Style{fg: :dark_gray}
    }
  end

  defp popup(%State{popup: nil}, _rect), do: nil

  defp popup(%State{popup: {kind, items, idx}}, messages_rect) do
    {title, list_items} =
      case kind do
        :model -> {" Pick a model ", items}
        :mode -> {" Pick a mode ", Enum.map(items, &inspect/1)}
      end

    list = %List{
      items: list_items,
      selected: idx,
      highlight_style: %Style{fg: :black, bg: :white, modifiers: [:bold]},
      highlight_symbol: "> "
    }

    popup_widget = %Popup{
      content: list,
      block: %Block{title: title, borders: [:all], border_type: :rounded},
      percent_width: 50,
      percent_height: 60
    }

    {popup_widget, messages_rect}
  end
end
