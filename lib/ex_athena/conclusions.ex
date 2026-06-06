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

  @type source :: :stated | :tail | :derived
  @type t :: %{text: String.t(), source: source()}

  @doc """
  Extract the conclusion for one turn from its assistant `text` and the names
  of the tool calls it made.
  """
  @spec from_turn(String.t() | nil, [String.t()]) :: {:ok, t()} | :none
  def from_turn(text, tool_names) do
    text = text || ""

    cond do
      stated = parse_marker(text) ->
        {:ok, %{text: stated, source: :stated}}

      blank?(text) and tool_names == [] ->
        :none

      blank?(text) ->
        {:ok, %{text: derive(tool_names), source: :derived}}

      true ->
        {:ok, %{text: tail_paragraph(text), source: :tail}}
    end
  end

  defp parse_marker(text) do
    case Regex.scan(@marker_re, text, capture: :all_but_first) do
      [] -> nil
      matches -> matches |> List.last() |> hd() |> String.trim()
    end
  end

  defp blank?(text), do: String.trim(text) == ""

  defp tail_paragraph(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> List.last()
    |> String.trim()
    |> truncate(@tail_max_chars)
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
