# Guarded on the OPTIONAL `:ex_ratatui` dep — this module references ExRatatui
# widget structs at compile time (e.g. `%ExRatatui.Widgets.Tabs{}`), so it
# can't compile for consumers that don't pull ex_ratatui. See ExAthena.Chat.Tui.
if Code.ensure_loaded?(ExRatatui.App) do
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
    alias ExRatatui.Text.{Line, Span}
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

      # Stash the layout rects so the App's mouse-event handler can route
      # clicks and wheel scrolls without recomputing the layout. Process
      # dict is per-process and is the same process the App callbacks run
      # in, so this is safe and cheap.
      tabs_rect = details_rect && %Rect{details_rect | height: 1}

      Process.put(:tui_layout, %{
        messages: messages_rect,
        details: details_rect,
        tabs: tabs_rect,
        tab_titles: details_tab_titles(state)
      })

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

    defp details_tab_titles(state) do
      tabs = State.details_tabs()
      Enum.map(tabs, &{&1, tab_title(&1, state)})
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
             messages_scroll: above_bottom,
             tool_blocks: tool_blocks
           },
           width,
           height
         ) do
      items =
        events
        |> Enum.flat_map(&event_to_widgets(&1, session.model, width, tool_blocks))
        |> append_throbber(loading?)

      %WidgetList{items: items, scroll_offset: scroll_offset(items, height, above_bottom)}
    end

    # One event can produce multiple widget rows — a tool block expands
    # into a header + indented preview lines + truncation hint, etc.
    defp event_to_widgets({:tool_block, id}, _model, width, tool_blocks) do
      case Map.get(tool_blocks, id) do
        nil -> [{%Paragraph{text: "● (missing tool block)", style: %Style{fg: :dark_gray}}, 1}]
        block -> render_tool_block(block, width)
      end
    end

    defp event_to_widgets(row, model, width, _tool_blocks),
      do: [row_widget(row, model, width)]

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

    defp changes(
           %State{git_diff_lines: lines, details_scroll: above_bottom, diff_mode: mode},
           width,
           height
         ) do
      {files, leading} = parse_git_diff(lines)

      items =
        cond do
          files == [] and leading == [] -> []
          files == [] -> Enum.map(leading, &noise_row(&1, width))
          true -> render_diff_files(files, leading, mode, width)
        end

      %WidgetList{
        items: items,
        scroll_offset: scroll_offset(items, height, above_bottom),
        block: @changes_block
      }
    end

    defp noise_row(line, width) do
      style =
        cond do
          String.starts_with?(line, "(no changes vs HEAD)") ->
            %Style{fg: :dark_gray, modifiers: [:italic]}

          String.starts_with?(line, "cwd: ") ->
            %Style{fg: :dark_gray, modifiers: [:italic]}

          String.starts_with?(line, "git diff failed") or
            String.starts_with?(line, "git diff crashed") or
              String.starts_with?(line, "`git` executable") ->
            %Style{fg: :red, modifiers: [:bold]}

          true ->
            %Style{fg: :dark_gray}
        end

      {%Paragraph{text: line, style: style, wrap: true}, wrapped_height(line, width)}
    end

    # ── Diff parser ──

    # Walks `git_diff_lines` and groups into per-file records.
    # Returns `{files, leading_lines}` where `leading_lines` is any
    # non-diff content before the first `diff --git` (status / error
    # messages from fetch_git_diff).
    defp parse_git_diff(lines) do
      {files, leading, _state} =
        Enum.reduce(lines, {[], [], :preamble}, &parse_line/2)

      {Enum.reverse(files) |> Enum.map(&finalize_file/1), Enum.reverse(leading)}
    end

    defp parse_line("diff --git " <> rest, {files, leading, state}) do
      files =
        case state do
          :preamble -> files
          _ -> finalize_state(files, state)
        end

      path = extract_diff_path(rest)
      {files, leading, {:file, %{path: path, additions: 0, deletions: 0, hunks: [], hunk: nil}}}
    end

    defp parse_line(line, {files, leading, :preamble}) do
      {files, [line | leading], :preamble}
    end

    defp parse_line("index " <> _, acc), do: acc

    defp parse_line("new file" <> _, {files, leading, {:file, f}}) do
      {files, leading, {:file, Map.put(f, :kind, :added)}}
    end

    defp parse_line("deleted file" <> _, {files, leading, {:file, f}}) do
      {files, leading, {:file, Map.put(f, :kind, :deleted)}}
    end

    defp parse_line("--- " <> _, acc), do: acc
    defp parse_line("+++ " <> _, acc), do: acc

    defp parse_line("@@" <> _ = header, {files, leading, {:file, f}}) do
      f = flush_hunk(f)
      {files, leading, {:file, Map.put(f, :hunk, %{header: header, lines: []})}}
    end

    defp parse_line("+" <> tail, {files, leading, {:file, %{hunk: h} = f}}) when not is_nil(h) do
      f = %{
        f
        | hunk: %{h | lines: h.lines ++ [{:added, tail}]},
          additions: f.additions + 1
      }

      {files, leading, {:file, f}}
    end

    defp parse_line("-" <> tail, {files, leading, {:file, %{hunk: h} = f}}) when not is_nil(h) do
      f = %{
        f
        | hunk: %{h | lines: h.lines ++ [{:removed, tail}]},
          deletions: f.deletions + 1
      }

      {files, leading, {:file, f}}
    end

    defp parse_line(" " <> tail, {files, leading, {:file, %{hunk: h} = f}}) when not is_nil(h) do
      f = %{f | hunk: %{h | lines: h.lines ++ [{:context, tail}]}}
      {files, leading, {:file, f}}
    end

    defp parse_line("\\ " <> _, acc), do: acc

    defp parse_line(_line, acc), do: acc

    defp flush_hunk(%{hunk: nil} = f), do: f

    defp flush_hunk(%{hunk: h, hunks: hunks} = f),
      do: %{f | hunks: hunks ++ [h], hunk: nil}

    defp finalize_file(f), do: flush_hunk(f) |> Map.drop([:hunk])

    defp finalize_state(files, {:file, f}), do: [f | files]
    defp finalize_state(files, _), do: files

    defp extract_diff_path(rest) do
      # rest is like "a/path b/path"; take the `b/` path (the post-image).
      case Regex.run(~r{ b/(.+)$}, rest) do
        [_, path] -> path
        _ -> String.trim(rest)
      end
    end

    # ── Per-file rendering ──

    defp render_diff_files(files, leading, mode, width) do
      leading_rows = Enum.map(leading, &noise_row(&1, width))
      body = Enum.flat_map(files, &render_file(&1, mode, width))
      leading_rows ++ body
    end

    defp render_file(file, mode, width) do
      header_text = file_header_text(file)

      header = {
        %Paragraph{
          text: header_text,
          style: %Style{fg: :light_yellow, modifiers: [:bold]},
          wrap: true
        },
        wrapped_height(header_text, width)
      }

      hunks = Enum.flat_map(file.hunks, &render_hunk(&1, mode, width))

      [header | hunks] ++ [{%Paragraph{text: " ", style: %Style{}}, 1}]
    end

    defp file_header_text(%{path: path} = f) do
      kind_label =
        case Map.get(f, :kind) do
          :added -> "new"
          :deleted -> "deleted"
          _ -> "modified"
        end

      stats =
        cond do
          f.additions > 0 and f.deletions > 0 -> " (+#{f.additions} -#{f.deletions})"
          f.additions > 0 -> " (+#{f.additions})"
          f.deletions > 0 -> " (-#{f.deletions})"
          true -> ""
        end

      "▸ #{path}  [#{kind_label}]#{stats}"
    end

    defp render_hunk(%{header: header, lines: lines}, :inline, _width) do
      header_row = {
        %Paragraph{text: "  " <> header, style: %Style{fg: :cyan}, wrap: false},
        1
      }

      body =
        Enum.map(lines, fn {kind, text} ->
          {prefix, style} =
            case kind do
              :added -> {"+ ", %Style{fg: :green}}
              :removed -> {"- ", %Style{fg: :red}}
              :context -> {"  ", %Style{fg: :dark_gray}}
            end

          full = "  " <> prefix <> text
          {%Paragraph{text: full, style: style, wrap: false}, 1}
        end)

      [header_row | body]
    end

    defp render_hunk(%{header: header, lines: lines}, :side_by_side, width) do
      header_row = {
        %Paragraph{text: "  " <> header, style: %Style{fg: :cyan}, wrap: false},
        1
      }

      col_width = max(div(width - 5, 2), 8)

      pair_rows =
        lines
        |> pair_hunk_lines()
        |> Enum.map(&render_side_by_side_pair(&1, col_width))

      [header_row | pair_rows]
    end

    # Pair `-` runs with the following `+` runs so they sit side by side.
    defp pair_hunk_lines(lines) do
      lines
      |> Enum.chunk_by(fn {kind, _} -> kind end)
      |> fold_runs([])
      |> Enum.reverse()
    end

    defp fold_runs([], acc), do: acc

    defp fold_runs([[{:context, _} | _] = run | rest], acc) do
      pairs = Enum.map(run, fn {:context, t} -> {{:context, t}, {:context, t}} end)
      fold_runs(rest, Enum.reverse(pairs) ++ acc)
    end

    defp fold_runs([[{:removed, _} | _] = lefts, [{:added, _} | _] = rights | rest], acc) do
      left_texts = Enum.map(lefts, fn {:removed, t} -> t end)
      right_texts = Enum.map(rights, fn {:added, t} -> t end)

      pairs =
        zip_pad(left_texts, right_texts)
        |> Enum.map(fn
          {nil, r} -> {{:none, ""}, {:added, r}}
          {l, nil} -> {{:removed, l}, {:none, ""}}
          {l, r} -> {{:removed, l}, {:added, r}}
        end)

      fold_runs(rest, Enum.reverse(pairs) ++ acc)
    end

    defp fold_runs([[{:removed, _} | _] = run | rest], acc) do
      pairs = Enum.map(run, fn {:removed, t} -> {{:removed, t}, {:none, ""}} end)
      fold_runs(rest, Enum.reverse(pairs) ++ acc)
    end

    defp fold_runs([[{:added, _} | _] = run | rest], acc) do
      pairs = Enum.map(run, fn {:added, t} -> {{:none, ""}, {:added, t}} end)
      fold_runs(rest, Enum.reverse(pairs) ++ acc)
    end

    defp fold_runs([_other | rest], acc), do: fold_runs(rest, acc)

    defp zip_pad([], []), do: []
    defp zip_pad([], [r | rs]), do: [{nil, r} | zip_pad([], rs)]
    defp zip_pad([l | ls], []), do: [{l, nil} | zip_pad(ls, [])]
    defp zip_pad([l | ls], [r | rs]), do: [{l, r} | zip_pad(ls, rs)]

    defp render_side_by_side_pair({left, right}, col_width) do
      line =
        Line.new([
          Span.new(side_text(left, col_width), style: side_style(left)),
          Span.new(" │ ", style: %Style{fg: :dark_gray}),
          Span.new(side_text(right, col_width), style: side_style(right))
        ])

      {%Paragraph{text: [line], wrap: false}, 1}
    end

    defp side_text({:none, _}, col_width), do: String.duplicate(" ", col_width)

    defp side_text({kind, text}, col_width) do
      prefix =
        case kind do
          :added -> "+ "
          :removed -> "- "
          :context -> "  "
        end

      body = prefix <> text
      cur = String.length(body)

      cond do
        cur > col_width -> String.slice(body, 0, col_width - 1) <> "…"
        true -> body <> String.duplicate(" ", col_width - cur)
      end
    end

    defp side_style({:added, _}), do: %Style{fg: :green}
    defp side_style({:removed, _}), do: %Style{fg: :red}
    defp side_style({:context, _}), do: %Style{fg: :dark_gray}
    defp side_style({:none, _}), do: %Style{}

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

    # ── Tool block (Claude-Code style: `● Tool(args)` + indented preview) ──

    defp render_tool_block(%{todos: todos} = block, width) when is_list(todos) do
      # Todo list: header + one row per item with a checkbox.
      bullet = status_bullet(block.status)

      header_text =
        "#{bullet} TodoWrite (#{length(todos)} item#{if length(todos) == 1, do: "", else: "s"})"

      header = {
        %Paragraph{
          text: header_text,
          style: %Style{fg: bullet_color(block.status), modifiers: [:bold]},
          wrap: true
        },
        wrapped_height(header_text, width)
      }

      {pending_and_active, completed} =
        Enum.split_with(todos, &(get_todo_status(&1) != "completed"))

      visible_rows =
        pending_and_active
        |> Enum.map(&todo_row_widget(&1, width))
        |> Kernel.++(maybe_collapsed_completed_row(completed, width))

      [header | visible_rows]
    end

    defp render_tool_block(block, width) do
      color = bullet_color(block.status)
      header_text = tool_header_text(block)

      header = {
        %Paragraph{
          text: header_text,
          style: %Style{fg: color, modifiers: [:bold]},
          wrap: true
        },
        wrapped_height(header_text, width)
      }

      preview_rows = preview_widget_rows(block, width)

      [header | preview_rows]
    end

    # ── Status bullet helpers ──

    defp status_bullet(:pending), do: "●"
    defp status_bullet(:success), do: "●"
    defp status_bullet(:error), do: "●"
    defp status_bullet(_), do: "●"

    defp bullet_color(:pending), do: :light_blue
    defp bullet_color(:success), do: :green
    defp bullet_color(:error), do: :red
    defp bullet_color(_), do: :dark_gray

    # ── Header rendering: `● Tool(args)` ──

    defp tool_header_text(%{name: name, ui: %{kind: :diff, payload: %{path: path}}})
         when name in ["edit", "write", "apply_patch"] do
      "#{status_bullet(:success)} #{verb_for(name)}(#{Path.relative_to_cwd(path)})"
    end

    defp tool_header_text(%{name: name, args: args}) do
      "#{status_bullet(:success)} #{tool_display_name(name)}(#{args_summary(name, args)})"
    end

    defp tool_display_name(name) do
      name
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("")
    end

    defp verb_for("write"), do: "Create"
    defp verb_for("apply_patch"), do: "Patch"
    defp verb_for(_), do: "Update"

    defp args_summary("bash", %{"command" => cmd}) when is_binary(cmd), do: truncate(cmd, 100)
    defp args_summary("bash", %{command: cmd}) when is_binary(cmd), do: truncate(cmd, 100)
    defp args_summary("read", args), do: get_arg(args, "path") |> Path.relative_to_cwd()
    defp args_summary("edit", args), do: get_arg(args, "path") |> Path.relative_to_cwd()
    defp args_summary("write", args), do: get_arg(args, "path") |> Path.relative_to_cwd()
    defp args_summary("grep", args), do: get_arg(args, "pattern")
    defp args_summary("glob", args), do: get_arg(args, "pattern")
    defp args_summary("web_fetch", args), do: args |> get_arg("url") |> truncate(80)
    defp args_summary(_name, args) when args == %{} or is_nil(args), do: ""
    defp args_summary(_name, args), do: args |> compact_args() |> truncate(80)

    defp get_arg(args, key) when is_map(args) do
      Map.get(args, key) || Map.get(args, String.to_atom(key)) || ""
    end

    defp get_arg(_args, _key), do: ""

    defp compact_args(args) when is_map(args) do
      Enum.map_join(args, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    end

    defp compact_args(other), do: inspect(other)

    # ── Indented preview rows ──

    defp preview_widget_rows(%{ui: %{kind: :diff, payload: payload}} = _block, width) do
      diff_preview_rows(payload, width)
    end

    defp preview_widget_rows(%{output_preview: nil}, _width), do: []

    defp preview_widget_rows(%{output_preview: [], total_lines: _}, _width), do: []

    defp preview_widget_rows(%{output_preview: lines, total_lines: total}, width) do
      visible_count = length(lines)
      preview_color = %Style{fg: :dark_gray}

      visible =
        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} ->
          text = if idx == 0, do: "  └ #{line}", else: "    #{line}"
          {%Paragraph{text: text, style: preview_color, wrap: true}, wrapped_height(text, width)}
        end)

      if total > visible_count do
        remaining = total - visible_count

        hint =
          "    … +#{remaining} line#{if remaining == 1, do: "", else: "s"} (/expand 1 for full)"

        visible ++
          [{%Paragraph{text: hint, style: %Style{fg: :dark_gray, modifiers: [:italic]}}, 1}]
      else
        visible
      end
    end

    # Edit / Write / apply_patch tool UI payloads carry the raw `before`
    # and `after` strings — not a pre-diffed line list — so we compute the
    # Myers diff inline. Same logic as ChatLive's `build_ui_entry(:diff)`
    # in the web LiveView (chat_live.ex:1568).
    defp diff_preview_rows(%{before: before, after: aft}, width) do
      before_lines = String.split(to_string(before), "\n")
      after_lines = String.split(to_string(aft), "\n")

      all_lines =
        Elixir.List.myers_difference(before_lines, after_lines)
        |> Enum.flat_map(fn
          {:eq, ls} -> Enum.map(ls, &{:eq, &1})
          {:ins, ls} -> Enum.map(ls, &{:ins, &1})
          {:del, ls} -> Enum.map(ls, &{:del, &1})
        end)

      added = Enum.count(all_lines, fn {k, _} -> k == :ins end)
      removed = Enum.count(all_lines, fn {k, _} -> k == :del end)

      stat_text =
        cond do
          added > 0 and removed > 0 -> "  └ +#{added} −#{removed} lines"
          added > 0 -> "  └ Added #{added} line#{if added == 1, do: "", else: "s"}"
          removed > 0 -> "  └ Removed #{removed} line#{if removed == 1, do: "", else: "s"}"
          true -> "  └ no net change"
        end

      stat_row =
        {%Paragraph{text: stat_text, style: %Style{fg: :dark_gray}, wrap: true},
         wrapped_height(stat_text, width)}

      snippet_rows =
        all_lines
        |> Enum.reject(fn {kind, _} -> kind == :eq end)
        |> Enum.take(6)
        |> Enum.map(fn {kind, line} ->
          {prefix, style} =
            case kind do
              :ins -> {"    + ", %Style{fg: :green}}
              :del -> {"    - ", %Style{fg: :red}}
              _ -> {"      ", %Style{fg: :dark_gray}}
            end

          text = prefix <> truncate(line, max(width - 6, 20))
          {%Paragraph{text: text, style: style, wrap: false}, 1}
        end)

      [stat_row | snippet_rows]
    end

    defp diff_preview_rows(_payload, _width), do: []

    # ── Todo list rendering ──

    defp todo_row_widget(todo, width) do
      {marker, color} = todo_marker(get_todo_status(todo))
      content = get_todo_field(todo, "content") || ""
      text = "  #{marker} #{content}"
      {%Paragraph{text: text, style: %Style{fg: color}, wrap: true}, wrapped_height(text, width)}
    end

    defp maybe_collapsed_completed_row([], _width), do: []

    defp maybe_collapsed_completed_row(completed, width) do
      n = length(completed)
      text = "    … +#{n} completed"

      [
        {%Paragraph{text: text, style: %Style{fg: :dark_gray, modifiers: [:italic]}, wrap: true},
         wrapped_height(text, width)}
      ]
    end

    defp todo_marker("completed"), do: {"✓", :green}
    defp todo_marker("in_progress"), do: {"◐", :light_blue}
    defp todo_marker(_), do: {"□", :dark_gray}

    defp get_todo_status(todo), do: get_todo_field(todo, "status") || "pending"

    defp get_todo_field(todo, key) when is_map(todo) do
      Map.get(todo, key) || Map.get(todo, String.to_atom(key))
    end

    defp get_todo_field(_, _), do: nil

    defp truncate(text, max) when is_binary(text) and is_integer(max) do
      if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
    end

    defp truncate(other, max), do: other |> to_string() |> truncate(max)

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
      {%Paragraph{text: text, style: %Style{fg: :yellow}, wrap: true},
       wrapped_height(text, width)}
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
end
