defmodule ExAthena.Compactors.Snip do
  @moduledoc """
  Second pipeline stage — drops *old* tool-result messages whose paired
  assistant turn already happened.

  Rationale (from Claude Code's `snipCompactIfNeeded`): once the model
  has *acted* on a tool result (asked the next question, synthesised
  conclusions, moved on), the raw verbose tool output is mostly dead
  weight. Dropping those — but only the older ones, leaving recent
  tool turns intact — keeps narrative continuity while reclaiming
  significant tokens deterministically.

  Heuristic:
    * a tool-role message older than `:snip_age_iterations` turns
      (default: 4) is eligible
    * **only** if there's a later assistant turn (so the model has
      already integrated the result)
    * the matching `tool_calls` slot on its parent assistant is
      replaced with a short `<snipped: id>` content stub so id-based
      pairing still parses cleanly

  Memory + skill messages and the live suffix are never touched.
  """

  @behaviour ExAthena.Compactor.Stage

  alias ExAthena.Compactor
  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message

  @default_age 4
  @live_suffix_count 6

  @impl true
  def name, do: :snip

  @impl true
  def compact_stage(%State{messages: messages} = state, estimate) do
    age_threshold = age_threshold(state)
    pin_floor = pin_floor(state)
    suffix_floor = max(length(messages) - @live_suffix_count, pin_floor)

    {snipped, count} = snip_old_tool_messages(messages, pin_floor, suffix_floor, age_threshold)

    case count do
      0 ->
        :skip

      _ ->
        new_state = %{state | messages: snipped}
        {:ok, new_state, %{estimate | tokens: Compactor.estimate_tokens(snipped)}}
    end
  end

  # ── Internals ────────────────────────────────────────────────────

  # Tool names whose results must survive snipping: todo_write is task
  # state; spawn_agent results are worker summaries — the orchestrator's
  # ONLY knowledge of completed work (re-running one costs a full worker).
  @protected_tools ~w(todo_write spawn_agent)

  defp snip_old_tool_messages(messages, pin_floor, suffix_floor, age_threshold) do
    indexed = Enum.with_index(messages)

    protected_ids =
      for %Message{role: :assistant, tool_calls: calls} <- messages,
          is_list(calls),
          call <- calls,
          call.name in @protected_tools,
          into: MapSet.new() do
        call.id
      end

    # Pre-compute index of last assistant turn so we can verify "model
    # has integrated this tool result already" cheaply.
    last_assistant_idx =
      indexed
      |> Enum.reverse()
      |> Enum.find_value(fn
        {%Message{role: :assistant}, idx} -> idx
        _ -> nil
      end)

    {result, count} =
      Enum.reduce(indexed, {[], 0}, fn {msg, idx}, {acc, c} ->
        cond do
          msg.pin ->
            {acc ++ [msg], c}

          idx < pin_floor or idx >= suffix_floor ->
            {acc ++ [msg], c}

          protected_result?(msg, protected_ids) ->
            {acc ++ [msg], c}

          tool_message_old_enough?(msg, idx, last_assistant_idx, age_threshold) ->
            {acc ++ [snip_marker(msg)], c + 1}

          true ->
            {acc ++ [msg], c}
        end
      end)

    {result, count}
  end

  defp protected_result?(%Message{role: :tool, tool_results: [tr | _]}, protected_ids),
    do: MapSet.member?(protected_ids, tr.tool_call_id)

  defp protected_result?(_, _), do: false

  defp tool_message_old_enough?(%Message{role: :tool}, idx, last_assistant_idx, age_threshold)
       when is_integer(last_assistant_idx) do
    last_assistant_idx - idx >= age_threshold
  end

  defp tool_message_old_enough?(_, _, _, _), do: false

  defp snip_marker(%Message{role: :tool, tool_results: results} = msg) when is_list(results) do
    snipped =
      Enum.map(results, fn res ->
        %{res | content: "<snipped: stale tool-result for call #{res.tool_call_id}>"}
      end)

    %{msg | tool_results: snipped}
  end

  defp snip_marker(msg), do: msg

  defp age_threshold(%State{meta: meta}) do
    Map.get(meta, :snip_age_iterations) ||
      case Application.get_env(:ex_athena, :compactor) do
        kw when is_list(kw) -> Keyword.get(kw, :snip_age_iterations, @default_age)
        m when is_map(m) -> Map.get(m, :snip_age_iterations, @default_age)
        _ -> @default_age
      end
  end

  defp pin_floor(%State{meta: meta}) do
    Map.get(meta, :memory_count, 0) +
      Map.get(meta, :preloaded_skill_count, 0) +
      Map.get(meta, :pinned_prefix_count, 1)
  end
end
