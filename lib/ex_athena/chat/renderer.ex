defmodule ExAthena.Chat.Renderer do
  @moduledoc """
  Pure-ish mapping of `ExAthena.Loop.Events` tuples to terminal output for the
  `mix athena.chat` REPL.

  The only side-effects here are `IO.write/1` (token-stream deltas, tool call
  hints, error notes) and building iodata for the pinned `Owl.LiveScreen`
  status block. Unknown events are silently dropped so the renderer can be
  forward-compatible with new event types in `ExAthena.Loop.Events`.
  """

  alias ExAthena.Messages.{ToolCall, ToolResult}

  @preview_chars 200

  @spec render_event(ExAthena.Loop.Events.t() | term()) :: :ok
  def render_event({:content, text}) when is_binary(text) do
    IO.write(text)
  end

  def render_event({:tool_call, %ToolCall{name: name, arguments: args}}) do
    arg_preview = preview_args(args)
    line = Owl.Data.tag("\n→ #{name}(#{arg_preview})", :cyan)
    Owl.IO.puts(line)
  end

  def render_event({:tool_result, %ToolResult{content: content, is_error: is_error}}) do
    color = if is_error, do: :red, else: :light_black
    preview = content |> to_string() |> truncate(@preview_chars)
    Owl.IO.puts(Owl.Data.tag("← #{preview}", color))
  end

  def render_event({:tool_ui, _payload}), do: :ok

  def render_event({:iteration, _n}), do: :ok

  def render_event({:usage, _u}), do: :ok

  def render_event({:compaction, %{before: before, after: aft}}) do
    Owl.IO.puts(Owl.Data.tag("⤵ compacted #{before}→#{aft} tokens", :yellow))
  end

  def render_event({:subagent_spawn, %{prompt: p}}) do
    Owl.IO.puts(Owl.Data.tag("  ↳ subagent: #{truncate(p, 80)}", :light_black))
  end

  def render_event({:subagent_result, %{text: t}}) do
    Owl.IO.puts(Owl.Data.tag("  ↳ subagent done: #{truncate(t, 80)}", :light_black))
  end

  def render_event({:error, reason}) do
    Owl.IO.puts(Owl.Data.tag("warn: #{inspect(reason)}", :yellow))
  end

  def render_event({:done, _result}) do
    IO.write("\n")
  end

  def render_event(_other), do: :ok

  @doc """
  Build iodata for the pinned `Owl.LiveScreen` status block.

  Renders a single dim line with `·` separators between fields:

      qwen3.5:latest · :react · iter=1 · 120/45 tok · $0.0042

  Accepts a status map with `:model`, `:mode`, `:iteration`, `:usage`, and
  `:cost_usd` keys.
  """
  @spec status_text(map()) :: IO.chardata()
  def status_text(%{model: model, mode: mode, iteration: iter, usage: usage, cost_usd: cost}) do
    Owl.Data.tag(
      [
        to_string(model),
        " · ",
        inspect(mode),
        " · iter=",
        Integer.to_string(iter),
        " · ",
        Integer.to_string(Map.get(usage, :input_tokens, 0)),
        "/",
        Integer.to_string(Map.get(usage, :output_tokens, 0)),
        " tok · $",
        :erlang.float_to_binary(cost / 1.0, decimals: 4)
      ],
      :light_black
    )
  end

  @doc """
  Build iodata for the per-turn assistant prefix line.

  Printed just before the model's streamed output, so it's clear which side
  of the conversation is speaking. Styled bold cyan.
  """
  @spec assistant_prefix(String.t()) :: IO.chardata()
  def assistant_prefix(model) when is_binary(model) do
    Owl.Data.tag([model, " ▸ "], [:cyan, :bright])
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
