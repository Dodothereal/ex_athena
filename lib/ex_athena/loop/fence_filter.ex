defmodule ExAthena.Loop.FenceFilter do
  @moduledoc """
  Pure streaming filter that removes `~~~tool_call ... ~~~` fenced blocks
  from chunked assistant text.

  Non-native-tool-call providers emit tool calls as text fences (the
  `ExAthena.ToolCalls.TextTagged` protocol, `~~~tool_call\\s*\\n ... \\n~~~`).
  When their output streams to hosts as `{:content, chunk}` deltas, the raw
  fence markup would leak into the visible transcript — the loop already
  surfaces the parsed calls as `{:tool_call, ...}` events, so the fences
  must be filtered out of the text stream.

  Chunks may split a marker at any byte boundary, so the filter holds the
  longest chunk tail that could still become a marker as *pending* text:

    * Outside a fence, a tail like `"~~"` or `"~~~tool_c"` (any strict
      prefix of `~~~tool_call`) is held instead of emitted. A complete
      `~~~tool_call` is also held while only optional whitespace follows —
      the open marker is `~~~tool_call\\s*\\n` (mirroring the TextTagged
      regex), so until the newline arrives we can't tell a fence from
      literal text like `~~~tool_caller`. If a non-whitespace char arrives
      first, the held text is released as visible.
    * Inside a fence, everything is swallowed until the close marker
      `\\n~~~`; a tail like `"\\n~"` is held the same way.

  `flush/1` ends the stream: pending text held outside a fence turned out
  to be real text and is returned; an unterminated fence is swallowed
  entirely (half a fence is still tool markup, and showing it is worse).
  """

  @open_marker "~~~tool_call"
  @close_marker "\n~~~"

  @opaque state :: {:outside, binary()} | {:inside, binary()}

  @doc "Create a fresh filter state (outside any fence, nothing pending)."
  @spec new() :: state()
  def new, do: {:outside, ""}

  @doc """
  Feed a chunk through the filter. Returns `{new_state, visible}` where
  `visible` is the text safe to show (may be `""` while inside a fence or
  while holding a possible partial marker).
  """
  @spec push(state(), binary()) :: {state(), binary()}
  def push({mode, pending}, chunk) when is_binary(chunk) do
    {state, iodata} = scan(mode, pending <> chunk, [])
    {state, IO.iodata_to_binary(iodata)}
  end

  @doc """
  End of stream. Releases pending text that never completed into an open
  marker; swallows the contents of an unterminated fence.
  """
  @spec flush(state()) :: binary()
  def flush({:outside, pending}), do: pending
  def flush({:inside, _pending}), do: ""

  # ── Scanner ─────────────────────────────────────────────────────────

  defp scan(mode, "", acc), do: {{mode, ""}, acc}

  defp scan(:outside, buffer, acc) do
    case :binary.match(buffer, @open_marker) do
      {i, len} ->
        before = binary_part(buffer, 0, i)
        rest = binary_part(buffer, i + len, byte_size(buffer) - i - len)

        case consume_marker_tail(rest) do
          # Marker + `\s*\n` complete: the fence body starts here.
          {:open, body} ->
            scan(:inside, body, [acc, before])

          # Marker seen but only (possibly empty) whitespace after it so
          # far — can't tell fence from literal text until more arrives.
          :partial ->
            {{:outside, @open_marker <> rest}, [acc, before]}

          # Non-whitespace before any newline (e.g. `~~~tool_caller`):
          # not a fence — release and keep scanning from the offender.
          {:no, ws, remainder} ->
            scan(:outside, remainder, [acc, before, @open_marker, ws])
        end

      :nomatch ->
        {held, emit} = hold_partial_suffix(buffer, @open_marker)
        {{:outside, held}, [acc, emit]}
    end
  end

  defp scan(:inside, buffer, acc) do
    case :binary.match(buffer, @close_marker) do
      {i, len} ->
        rest = binary_part(buffer, i + len, byte_size(buffer) - i - len)
        scan(:outside, rest, acc)

      :nomatch ->
        # Swallow the body; hold only a tail that could be a partial close.
        {held, _swallowed} = hold_partial_suffix(buffer, @close_marker)
        {{:inside, held}, acc}
    end
  end

  # After `~~~tool_call`: skip whitespace looking for the newline that
  # completes the open marker (`\s*\n`).
  defp consume_marker_tail(rest), do: consume_marker_tail(rest, "")

  defp consume_marker_tail("", _ws), do: :partial
  defp consume_marker_tail(<<?\n, rest::binary>>, _ws), do: {:open, rest}

  defp consume_marker_tail(<<c, rest::binary>>, ws) when c in [?\s, ?\t, ?\r, ?\f, ?\v],
    do: consume_marker_tail(rest, <<ws::binary, c>>)

  defp consume_marker_tail(rest, ws), do: {:no, ws, rest}

  # Split `buffer` into `{held, emit}` where `held` is the longest suffix
  # of `buffer` that is a strict prefix of `marker` (it may complete into
  # the marker on the next chunk); everything before it is safe to emit.
  defp hold_partial_suffix(buffer, marker) do
    max_n = min(byte_size(marker) - 1, byte_size(buffer))

    held =
      Enum.reduce_while(max_n..1//-1, "", fn n, _ ->
        suffix = binary_part(buffer, byte_size(buffer) - n, n)

        if String.starts_with?(marker, suffix),
          do: {:halt, suffix},
          else: {:cont, ""}
      end)

    {held, binary_part(buffer, 0, byte_size(buffer) - byte_size(held))}
  end
end
