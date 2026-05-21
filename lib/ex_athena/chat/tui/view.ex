defmodule ExAthena.Chat.Tui.View do
  @moduledoc """
  Pure view function for `ExAthena.Chat.Tui`. Turns a `%State{}` into the
  list of `{widget, %Rect{}}` tuples the ex_ratatui runtime needs.

  Layout (top-to-bottom):

    1. Header (1 row) — `provider · model · mode · iter=N · in/out tok · $cost`.
    2. Messages (flex) — a `WidgetList` of one `{Paragraph, 1}` per event row.
       If `state.loading? == true`, a `Throbber` is appended to the list.
    3. Input (3 rows) — `Textarea` bound to `state.input_ref` inside a
       titled `Block`.
    4. Footer (1 row) — shortcut hints (changes when a popup is open).

  When `state.popup != nil`, a `Popup` widget overlays the messages
  rect with a centered `List`.
  """

  alias ExAthena.Chat.{Session, Tui.State}
  alias ExRatatui.Frame
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph, Popup, Textarea, Throbber, WidgetList}

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

    [header_rect, messages_rect, input_rect, footer_rect] =
      Layout.split(area, :vertical, [
        {:length, 1},
        {:min, 0},
        {:length, @input_height},
        {:length, @footer_height}
      ])

    widgets = [
      {header(state), header_rect},
      {messages(state), messages_rect},
      {input(state), input_rect},
      {footer(state), footer_rect}
    ]

    case popup(state, messages_rect) do
      nil -> widgets
      popup_tuple -> widgets ++ [popup_tuple]
    end
  end

  @doc "Build the header status string from a session."
  @spec status_line(Session.t()) :: String.t()
  def status_line(%Session{} = s) do
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
      :erlang.float_to_binary(s.cost_usd / 1.0, decimals: 4)
    ])
  end

  defp header(%State{session: session}) do
    %Paragraph{
      text: status_line(session),
      style: %Style{fg: :light_blue},
      alignment: :left
    }
  end

  defp messages(%State{
         events: events,
         loading?: loading?,
         scroll_offset: scroll,
         session: session
       }) do
    items =
      events
      |> Enum.map(&row_widget(&1, session.model))
      |> append_throbber(loading?)

    %WidgetList{items: items, scroll_offset: scroll}
  end

  defp row_widget({:user, text}, _model) do
    {%Paragraph{
       text: "me ▸ " <> text,
       style: %Style{fg: :green, modifiers: [:bold]}
     }, 1}
  end

  defp row_widget({:assistant, text}, model) do
    {%Paragraph{
       text: model <> " ▸ " <> text,
       style: %Style{fg: :cyan, modifiers: [:bold]}
     }, 1}
  end

  defp row_widget({:tool_call, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :cyan}}, 1}
  end

  defp row_widget({:tool_result, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}}, 1}
  end

  defp row_widget({:tool_result_error, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :red}}, 1}
  end

  defp row_widget({:warning, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :yellow}}, 1}
  end

  defp row_widget({:error, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :red, modifiers: [:bold]}}, 1}
  end

  defp row_widget({:info, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}}, 1}
  end

  defp row_widget({:status, text}, _model) do
    {%Paragraph{text: text, style: %Style{fg: :dark_gray}}, 1}
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
