defmodule ExAthena.Compactors.ObservationMask do
  @moduledoc """
  Observation masking — the research-validated middle layer between
  source-side tool caps and whole-transcript summarization.

  Replaces tool RESULTS older than a protected recency tail with short,
  RESTORABLE placeholders (the tool call itself — name + args — stays
  intact, so pairing is preserved and the model can re-run the tool).

  Evidence (June 2026): JetBrains "The Complexity Trap" — masking matches
  or beats LLM summarization on SWE-bench at half the cost, and avoids
  summarization's failure mode of smoothing over error signals (agents
  loop ~15% longer when summaries hide how stuck they are). Anthropic's
  context editing ships the same shape (+29% agentic eval, −84% tokens).

  Rules:
    * never mask the last #{5} tool results (protected tail)
    * never mask ERROR results — failure evidence prevents repeated
      mistakes (Manus)
    * never mask state-bearing tools (todo_write)
    * batched: only runs when ≥ a minimum is reclaimable — every edit
      point invalidates the prefix cache once, so make it count
  """

  @behaviour ExAthena.Compactor.Stage

  alias ExAthena.Compactor
  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message

  @keep_last 5
  @min_reclaim_chars 10_000
  @protected_tools ~w(todo_write)
  @placeholder_prefix "[output cleared to save context"

  @impl true
  def name, do: :observation_mask

  @impl true
  def compact_stage(%State{messages: messages} = state, estimate) do
    call_index = index_calls(messages)
    maskable = maskable_indices(messages, call_index)

    reclaim =
      Enum.reduce(maskable, 0, fn idx, acc ->
        acc + content_size(Enum.at(messages, idx))
      end)

    if maskable == [] or reclaim < @min_reclaim_chars do
      :skip
    else
      masked =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          if idx in maskable, do: mask(msg, call_index), else: msg
        end)

      {:ok, %{state | messages: masked}, %{estimate | tokens: Compactor.estimate_tokens(masked)}}
    end
  end

  # tool_call_id → {tool_name, args} from the assistant messages, so masks
  # can name the tool and keep a restorable hint.
  defp index_calls(messages) do
    for %Message{role: :assistant, tool_calls: calls} <- messages,
        is_list(calls),
        call <- calls,
        into: %{} do
      {call.id, {call.name, call.arguments}}
    end
  end

  defp maskable_indices(messages, call_index) do
    tool_indices =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _idx} -> maskable_message?(msg, call_index) end)
      |> Enum.map(fn {_msg, idx} -> idx end)

    Enum.drop(tool_indices, -@keep_last)
  end

  defp maskable_message?(%Message{role: :tool, pin: false, tool_results: [tr | _]}, call_index) do
    {name, _args} = Map.get(call_index, tr.tool_call_id, {nil, %{}})

    is_binary(tr.content) and
      tr.is_error != true and
      name not in @protected_tools and
      not String.starts_with?(tr.content, @placeholder_prefix)
  end

  defp maskable_message?(_msg, _call_index), do: false

  defp mask(%Message{tool_results: [tr | rest]} = msg, call_index) do
    {name, args} = Map.get(call_index, tr.tool_call_id, {"tool", %{}})

    placeholder =
      "#{@placeholder_prefix} (#{byte_size(tr.content)} chars) — " <>
        "re-run #{name || "the tool"}#{hint(args)} if needed]"

    %{msg | tool_results: [%{tr | content: placeholder, ui_payload: nil} | rest]}
  end

  # Restorable hint (Manus rule: drop content, keep the address).
  defp hint(args) when is_map(args) do
    case args["path"] || args["url"] || args["command"] || args["pattern"] do
      v when is_binary(v) and v != "" -> " (#{String.slice(v, 0, 80)})"
      _ -> ""
    end
  end

  defp hint(_), do: ""

  defp content_size(%Message{tool_results: [%{content: c} | _]}) when is_binary(c),
    do: byte_size(c)

  defp content_size(_), do: 0
end
