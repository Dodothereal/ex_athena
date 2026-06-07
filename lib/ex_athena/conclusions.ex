defmodule ExAthena.Conclusions do
  @moduledoc """
  Per-iteration conclusion extraction.

  Every loop iteration should leave a one-line record of what was concluded —
  the host Overview renders these as a progress timeline, and the rolling
  ledger is recited back to the model (Manus-style) to keep long runs on
  track. The lineage is ReAct's `Thought:` prefixes → Magentic-One's progress
  ledger → Manus's todo recitation, scaled down to ZERO extra LLM calls
  (mandatory on 1-3-slot local GPUs).

  The contract is lenient by design (small local models drift on strict
  formats), with a three-stage fallback chain:

    1. **`:stated`** — the model ended its turn with `CONCLUSION: <text>`
       (the prompt contract; last marker wins).
    2. **`:tail`** — no marker: the final paragraph of the turn's text,
       truncated. For terminal answers the final paragraph ≈ the conclusion.
    3. **`:derived`** — no usable text: synthesized from the turn's tool
       calls ("ran read, grep").

  A turn with neither text nor tool calls yields `:none` — nothing happened
  worth recording (e.g. an empty provider response).
  """

  @marker_re ~r/^CONCLUSION:\s*(.+)$/m
  @tail_max_chars 160
  # Whole-thinking conclusions get a generous cap — the blob IS the record.
  @thinking_max_chars 1_000

  @type source :: :stated | :tail | :thinking | :derived
  @type t :: %{text: String.t(), source: source()}

  @doc """
  Extract the conclusion for one turn from its assistant `text`, its
  `thinking` (reasoning channel), and the names of the tool calls it made.

  Thinking models (Qwen3.5 et al.) put everything — including the
  CONCLUSION line the contract asks for — inside the reasoning channel,
  leaving the text channel of tool-call turns blank. Without thinking as a
  source, every conclusion degraded to the "ran bash" fallback.
  """
  @spec from_turn(String.t() | nil, String.t() | nil, [String.t()]) :: {:ok, t()} | :none
  def from_turn(text, thinking \\ nil, tool_names)

  def from_turn(text, thinking, tool_names) do
    text = text || ""
    thinking = thinking || ""

    cond do
      stated = parse_marker(text) ->
        {:ok, %{text: stated, source: :stated}}

      stated = parse_marker(thinking) ->
        {:ok, %{text: stated, source: :stated}}

      not blank?(text) ->
        {:ok, %{text: tail_paragraph(text), source: :tail}}

      not blank?(thinking) ->
        # Thinking models leave the text channel blank on tool turns and
        # ignore format nags — the WHOLE reasoning blob carries the turn's
        # record (tail-only extraction yielded forward-looking junk). The
        # distinct :thinking source lets the recitation truncate/age these
        # (full blobs go to the UI and failure digests only).
        {:ok,
         %{text: thinking |> String.trim() |> truncate(@thinking_max_chars), source: :thinking}}

      tool_names == [] ->
        :none

      true ->
        {:ok, %{text: derive(tool_names), source: :derived}}
    end
  end

  defp parse_marker(text) do
    case Regex.scan(@marker_re, text, capture: :all_but_first) do
      [] -> nil
      matches -> matches |> List.last() |> hd() |> String.trim()
    end
  end

  defp blank?(text), do: String.trim(text) == ""

  # Forward-looking openers — intent for the NEXT action, not a conclusion.
  # Thinking models end almost every reasoning block with one of these;
  # the actual finding sits a paragraph earlier.
  @intent_re ~r/^(let me|let's|i'll|i will|i need|i should|now i|now,|next,|next i|first,|time to)\b/i

  defp tail_paragraph(text) do
    paragraphs =
      text
      |> String.split(~r/\n\s*\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    chosen =
      paragraphs
      |> Enum.reverse()
      |> Enum.find(fn p -> not Regex.match?(@intent_re, p) end)
      |> Kernel.||(List.last(paragraphs))

    truncate(chosen, @tail_max_chars)
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  defp derive(tool_names) do
    "ran " <> (tool_names |> Enum.uniq() |> Enum.join(", "))
  end
end
