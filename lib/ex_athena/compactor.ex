defmodule ExAthena.Compactor do
  @moduledoc """
  Behaviour for context-window compaction.

  When the conversation's estimated token footprint crosses
  `:compact_at` (fraction of the provider's `max_tokens`), the loop asks
  the Compactor to reduce history size. The Compactor's job is to preserve
  **intent** + **pinned rules** while replacing the middle of history with
  a summary.

  ## Contract

  - **Pinned prefix**: the first N messages (`:pinned_prefix_count`) are
    never dropped. System prompts + CLAUDE.md-style pinned rules live
    there.
  - **Live suffix**: the last K messages (`:live_suffix_count`) are
    never dropped. Recent context the model needs to keep reasoning.
  - **Middle**: everything between is the Compactor's to replace. It may
    emit zero or more summary messages that sit where the dropped
    messages used to be.

  Default implementation `ExAthena.Compactors.Summary` uses the session's
  own provider to generate a terse summary message and substitutes it.
  Consumers can swap in any module via `config :ex_athena, compactor:
  MyApp.MyCompactor`.

  ## Why

  Research (Anthropic `compact_20260112` beta, Cline, Claude Agent SDK):
  proactive compaction at ~60% of the context limit beats reactive
  truncation at 95% — the model never notices a sudden loss of
  continuity, and pinned rules survive every compaction cycle.
  """

  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message

  @type estimate :: %{
          required(:tokens) => non_neg_integer(),
          required(:max_tokens) => non_neg_integer()
        }

  @type decision ::
          {:compact, messages :: [Message.t()], metadata :: map()}
          | :skip
          | {:error, term()}

  @doc """
  Run compaction against the current state. Return one of:

    * `{:compact, new_messages, metadata}` — the kernel swaps
      `state.messages` for `new_messages` and emits a `{:compaction, …}`
      event with `metadata`.
    * `:skip` — do nothing this cycle (e.g. compactor judged compaction
      not yet necessary). The kernel emits no event.
    * `{:error, reason}` — terminate the run with
      `:error_compaction_failed`.
  """
  @callback compact(State.t(), estimate()) :: decision()

  @doc """
  Whether compaction should run this turn. The kernel calls this before
  `compact/2` so the compactor can defer cheaply without having to build
  a summary.
  """
  @callback should_compact?(State.t(), estimate()) :: boolean()

  @optional_callbacks [should_compact?: 2]

  @doc """
  Best-effort token estimator. Counts ~4 chars per token for text
  content, plus a small fixed cost per tool-call to cover the JSON
  envelope. Good enough for compaction triggers; not a billing number.

  Pass the request's `system_prompt` as the second argument to include its
  cost in the estimate. The system prompt (which carries tool descriptions
  and skill catalogs) is part of every request and can run to thousands of
  tokens, so omitting it makes the proactive `should_compact?` trigger fire
  later than it should — or not at all on prompt-heavy agents.
  """
  @spec estimate_tokens([Message.t()], String.t() | nil) :: non_neg_integer()
  def estimate_tokens(messages, system_prompt \\ nil) do
    msg_tokens = Enum.reduce(messages, 0, fn msg, acc -> acc + tokens_for(msg) end)
    msg_tokens + system_prompt_tokens(system_prompt)
  end

  defp system_prompt_tokens(prompt) when is_binary(prompt), do: div(byte_size(prompt), 4)
  defp system_prompt_tokens(_), do: 0

  defp tokens_for(%Message{content: nil, tool_calls: calls}) when is_list(calls) do
    Enum.reduce(calls, 0, fn tc, acc ->
      acc + 64 + div(byte_size(Jason.encode!(tc.arguments || %{})), 4)
    end)
  end

  # Tool-result messages can carry kilobytes of bash/Read output. Counting
  # them as a fixed 16 lets compaction's `should_compact?` underestimate the
  # real prompt by ~10× — observed in production where a 94K-token prompt
  # was reported as ~5K and compaction never fired before max_iterations.
  defp tokens_for(%Message{role: :tool, tool_results: results}) when is_list(results) do
    Enum.reduce(results, 0, fn tr, acc -> acc + 16 + result_tokens(tr) end)
  end

  defp tokens_for(%Message{content: content}) when is_binary(content),
    do: div(byte_size(content), 4) + 8

  defp tokens_for(_), do: 16

  defp result_tokens(%{content: content}) when is_binary(content),
    do: div(byte_size(content), 4)

  defp result_tokens(_), do: 0
end
