defmodule ExAthena.Loop.Terminations do
  @moduledoc """
  Typed termination subtypes for agent-loop runs.

  Every run ends with exactly one termination. Normal completions use `:stop`;
  everything else is an error subtype carrying enough context (usage, cost,
  duration) to drive retries and observability.

  Inspired by the Claude Agent SDK's typed termination subtypes — they keep
  accounting uniform across happy and sad paths.

  ## Subtypes

    * `:stop` — model returned text with no tool calls.
    * `:submitted` — model explicitly called the `finish` tool to declare
      completion. The `Result.deliverable` field carries the payload.
    * `:error_max_turns` — iteration cap reached.
    * `:error_max_budget_usd` — cost ceiling tripped.
    * `:error_during_execution` — unrecoverable tool / provider error.
    * `:error_max_structured_output_retries` — repair budget exhausted.
    * `:error_consecutive_mistakes` — mistake counter threshold hit.
    * `:error_halted` — hook or tool returned `:halt`.
    * `:error_compaction_failed` — context compaction failed.
    * `:error_prompt_too_long` — provider rejected the request because the
      assembled prompt exceeded the model's context window. Modes signal this
      to the kernel so the compaction pipeline can attempt reactive recovery
      before the run terminates.
    * `:error_no_progress` — consecutive-iteration productivity threshold
      exceeded; the last N iterations produced identical tool calls with no
      new text. The `Result.no_progress_snapshot` field carries the stuck
      message pairs for remediation reprompts.
    * `:error_schema_validation` — model output could not be parsed as valid
      structured output or tool calls. Category `:retryable`; caller may retry
      with a reformat prompt hint. `Result.error_diagnostic` carries the
      structured failure payload.
    * `:error_provider_auth` — provider returned HTTP 401 or 403. Category
      `:fatal`; blind retry will not help — operator must fix credentials.
  """

  @type subtype ::
          :stop
          | :submitted
          | :error_max_turns
          | :error_max_budget_usd
          | :error_during_execution
          | :error_max_structured_output_retries
          | :error_consecutive_mistakes
          | :error_halted
          | :error_compaction_failed
          | :error_prompt_too_long
          | :error_no_progress
          | :error_schema_validation
          | :error_provider_auth

  @all_subtypes [
    :stop,
    :submitted,
    :error_max_turns,
    :error_max_budget_usd,
    :error_during_execution,
    :error_max_structured_output_retries,
    :error_consecutive_mistakes,
    :error_halted,
    :error_compaction_failed,
    :error_prompt_too_long,
    :error_no_progress,
    :error_schema_validation,
    :error_provider_auth
  ]

  @doc "All known termination subtypes."
  @spec all() :: [subtype()]
  def all, do: @all_subtypes

  @doc "Is this a successful termination?"
  @spec success?(subtype()) :: boolean()
  def success?(:stop), do: true
  def success?(:submitted), do: true
  def success?(_), do: false

  @doc "Is this an error termination?"
  @spec error?(subtype()) :: boolean()
  def error?(:stop), do: false
  def error?(:submitted), do: false
  def error?(_), do: true

  @doc """
  Categorise a termination for retry classification. Returns one of:
  `:retryable`, `:capacity`, `:fatal`.

    * `:retryable` — transient; caller may retry on a new run.
    * `:capacity` — the run hit a configured limit; caller should increase
      the limit or reduce scope.
    * `:fatal` — don't retry without operator action.
  """
  @spec category(subtype()) :: :success | :retryable | :capacity | :fatal
  def category(:stop), do: :success
  def category(:submitted), do: :success
  def category(:error_max_turns), do: :capacity
  def category(:error_max_budget_usd), do: :capacity
  def category(:error_max_structured_output_retries), do: :capacity
  def category(:error_consecutive_mistakes), do: :capacity
  def category(:error_during_execution), do: :retryable
  def category(:error_schema_validation), do: :retryable
  def category(:error_prompt_too_long), do: :capacity
  def category(:error_no_progress), do: :capacity
  def category(:error_halted), do: :fatal
  def category(:error_compaction_failed), do: :fatal
  def category(:error_provider_auth), do: :fatal
end
