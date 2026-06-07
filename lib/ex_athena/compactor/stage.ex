defmodule ExAthena.Compactor.Stage do
  @moduledoc """
  Behaviour for a single compaction stage.

  A stage is one cheap-to-expensive transformation in the
  `ExAthena.Compactor.Pipeline`. The pipeline runs stages in order;
  each stage may shrink the conversation a little (returning the new
  estimate) or skip (returning `:skip`). Earlier stages run before
  later ones, so cheap deterministic transformations get to reduce
  the budget before the LLM-summary stage pays for inference.

  ## Contract

  Each stage receives the current `Loop.State` and a token estimate. It
  returns:

    * `{:ok, new_state, new_estimate}` — applied a reduction.
    * `:skip` — nothing to do this pass.
    * `{:error, reason}` — surfaces to the kernel as
      `:error_compaction_failed`. The pipeline aborts.

  Stages should be **idempotent** when re-run on a state they already
  processed (the reactive-recovery path may run the pipeline a second
  time with `force: true` after a context-window error).

  ## Optional `force?/2` callback

  The pipeline calls `force?(state, estimate)` to ask whether a stage
  should run *unconditionally* on the recovery path (where the goal
  is "shrink as much as possible"). The default implementation returns
  `true`.
  """

  alias ExAthena.Compactor
  alias ExAthena.Loop.State

  @type result ::
          {:ok, State.t(), Compactor.estimate()}
          | :skip
          | {:error, term()}

  @callback compact_stage(State.t(), Compactor.estimate()) :: result()

  @doc "Stage's display name (atom). Used in telemetry."
  @callback name() :: atom()

  @optional_callbacks []

  @doc """
  Default builtin pipeline ordering. Stages are placed cheapest-first
  so the LLM-summary stage only fires when the deterministic stages
  couldn't get the conversation under target.
  """
  @spec default_pipeline() :: [module()]
  def default_pipeline do
    # ObservationMask is the workhorse (JetBrains/Anthropic evidence:
    # aging out old tool results beats summarization for agent loops);
    # Summary stays the last resort. ContextCollapse was REMOVED from the
    # default: its meta[:compact_view] is read by nothing, yet it lowered
    # the token estimate — short-circuiting Summary while the real prompt
    # stayed oversized (overflow persisted).
    [
      ExAthena.Compactors.BudgetReduction,
      ExAthena.Compactors.Snip,
      ExAthena.Compactors.ObservationMask,
      ExAthena.Compactors.Microcompact,
      ExAthena.Compactors.Summary
    ]
  end
end
