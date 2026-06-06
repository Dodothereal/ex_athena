defmodule ExAthena.Loop.FenceFilter do
  @moduledoc """
  Pure streaming filter that removes `~~~tool_call ... ~~~` and
  `~~~tool_result ... ~~~` fenced blocks from chunked assistant text.

  Non-native-tool-call providers emit tool calls as text fences (the
  `ExAthena.ToolCalls.TextTagged` protocol, `~~~tool_call\\s*\\n ... \\n~~~`).
  Some models additionally roleplay the *result* side, echoing
  `~~~tool_result` fences (often with invented tool output) into their
  visible text. When this output streams to hosts as `{:content, chunk}`
  deltas, the raw fence markup leaks into the transcript — the loop already
  surfaces real tool activity as `{:tool_call, ...}` / `{:tool_result, ...}`
  events, so both fence kinds must be stripped from the text stream.

  Chunks may split a marker at any byte boundary, so the filter holds the
  longest chunk tail that could still become a marker as *pending* text:

    * Outside a fence, a tail like `"~~"`, `"~~~tool_"` (shared by both
      markers), `"~~~tool_c"` (only `~~~tool_call`), or `"~~~tool_r"` (only
      `~~~tool_result`) — any strict prefix of *either* open marker — is
      held instead of emitted. A complete `~~~tool_call` / `~~~tool_result`
      is also held while only optional whitespace follows — the open marker
      is `<marker>\\s*\\n` (mirroring the TextTagged regex), so until the
      newline arrives we can't tell a fence from literal text like
      `~~~tool_caller`. If a non-whitespace char arrives first, the held
      text is released as visible.
    * Inside a fence, everything is swallowed until the close marker
      `\\n~~~`; a tail like `"\\n~"` is held the same way.

  `flush/1` ends the stream: pending text held outside a fence turned out
  to be real text and is returned; an unterminated fence is swallowed
  entirely (half a fence is still tool markup, and showing it is worse).
  """

  @open_markers ["~~~tool_call", "~~~tool_result"]
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
    # `:binary.match/2` with a pattern list returns the earliest match; the
    # two markers diverge after the shared `~~~tool_` prefix so they can never
    # start at the same position, leaving no ambiguity over which matched.
    case :binary.match(buffer, @open_markers) do
      {i, len} ->
        marker = binary_part(buffer, i, len)
        before = binary_part(buffer, 0, i)
        rest = binary_part(buffer, i + len, byte_size(buffer) - i - len)

        case consume_marker_tail(rest) do
          # Marker + `\s*\n` complete: the fence body starts here.
          {:open, body} ->
            scan(:inside, body, [acc, before])

          # Marker seen but only (possibly empty) whitespace after it so
          # far — can't tell fence from literal text until more arrives.
          :partial ->
            {{:outside, marker <> rest}, [acc, before]}

          # Non-whitespace before any newline (e.g. `~~~tool_caller`):
          # not a fence — release and keep scanning from the offender.
          {:no, ws, remainder} ->
            scan(:outside, remainder, [acc, before, marker, ws])
        end

      :nomatch ->
        {held, emit} = hold_partial_suffix(buffer, @open_markers)
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

  # Split `buffer` into `{held, emit}` where `held` is the longest suffix of
  # `buffer` that is a strict prefix of `marker` — or, given a list of markers,
  # of *any* of them (it may complete into a marker on the next chunk);
  # everything before it is safe to emit.
  defp hold_partial_suffix(buffer, markers) do
    markers = List.wrap(markers)
    longest = markers |> Enum.map(&byte_size/1) |> Enum.max()
    max_n = min(longest - 1, byte_size(buffer))

    held =
      Enum.reduce_while(max_n..1//-1, "", fn n, _ ->
        suffix = binary_part(buffer, byte_size(buffer) - n, n)

        if Enum.any?(markers, &String.starts_with?(&1, suffix)),
          do: {:halt, suffix},
          else: {:cont, ""}
      end)

    {held, binary_part(buffer, 0, byte_size(buffer) - byte_size(held))}
  end
end
