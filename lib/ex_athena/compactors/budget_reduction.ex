defmodule ExAthena.Compactors.BudgetReduction do
  @moduledoc """
  First stage of the compaction pipeline. Replaces oversized tool-result
  contents with a short reference pointer.

  The pattern is from Claude Code's `applyToolResultBudget`: any tool
  result whose content exceeds `:per_tool_result_max_chars` (default
  16_000 characters) is swapped for a placeholder describing the size
  and a stable reference id. The full payload moves to
  `state.assigns[:tool_result_archive]` so a future reload tool (PR2
  ships only the archive plumbing; reload tooling is host-side) can
  restore it.

  This stage is deterministic and cheap — no LLM calls, no message
  drops. It runs before Snip / Microcompact / ContextCollapse / Summary
  and often gets the conversation under target on its own when one
  outlier tool produced a giant response (think: a `Read` of a 100KB
  file or a `Bash` `grep` over a huge tree).
  """

  @behaviour ExAthena.Compactor.Stage

  alias ExAthena.Compactor
  alias ExAthena.Loop.State
  alias ExAthena.Messages.{Message, ToolResult}

  @default_max_chars 16_000

  @impl true
  def name, do: :budget_reduction

  @impl true
  def compact_stage(%State{} = state, estimate) do
    max_chars = max_chars(state)
    archive = Map.get(state.meta, :tool_result_archive, %{})

    {messages, archive, replaced} = walk(state.messages, max_chars, archive, 0)

    case replaced do
      0 ->
        :skip

      _ ->
        new_state =
          %{
            state
            | messages: messages,
              meta: Map.put(state.meta, :tool_result_archive, archive)
          }

        new_estimate = %{estimate | tokens: Compactor.estimate_tokens(messages)}

        {:ok, new_state, new_estimate}
    end
  end

  # ── Internals ────────────────────────────────────────────────────

  defp walk(messages, max_chars, archive, replaced) do
    Enum.reduce(messages, {[], archive, replaced}, fn msg, {acc, ar, r} ->
      case shrink(msg, max_chars, ar) do
        {:kept, m} -> {acc ++ [m], ar, r}
        {:replaced, m, ar2} -> {acc ++ [m], ar2, r + 1}
      end
    end)
  end

  defp shrink(%Message{role: :tool, tool_results: results} = msg, max_chars, archive)
       when is_list(results) do
    {new_results, archive, any_replaced?} =
      Enum.reduce(results, {[], archive, false}, fn res, {acc, ar, hit?} ->
        case shrink_result(res, max_chars, ar) do
          {:kept, r} -> {acc ++ [r], ar, hit?}
          {:replaced, r, ar2} -> {acc ++ [r], ar2, true}
        end
      end)

    if any_replaced? do
      {:replaced, %{msg | tool_results: new_results}, archive}
    else
      {:kept, msg}
    end
  end

  defp shrink(msg, _max_chars, _archive), do: {:kept, msg}

  defp shrink_result(%ToolResult{content: content} = res, max_chars, archive)
       when is_binary(content) do
    if byte_size(content) > max_chars do
      ref = generate_ref()
      # Honest placeholder: there is no reload-by-ref mechanism — advertising
      # one invited hallucinated tool calls. Tell the model how to recover.
      placeholder =
        "[old output cleared to save context (#{byte_size(content)} chars, ref=#{ref}) — " <>
          "re-run the tool with narrower arguments if needed]"

      new_archive =
        Map.put(archive, ref, %{
          tool_call_id: res.tool_call_id,
          content: content,
          truncated_at: System.system_time(:millisecond)
        })

      {:replaced, %{res | content: placeholder}, new_archive}
    else
      {:kept, res}
    end
  end

  defp shrink_result(res, _max_chars, _archive), do: {:kept, res}

  defp max_chars(%State{meta: meta}) do
    Map.get(meta, :per_tool_result_max_chars) ||
      case Application.get_env(:ex_athena, :compactor) do
        kw when is_list(kw) -> Keyword.get(kw, :per_tool_result_max_chars, @default_max_chars)
        m when is_map(m) -> Map.get(m, :per_tool_result_max_chars, @default_max_chars)
        _ -> @default_max_chars
      end
  end

  defp generate_ref do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
