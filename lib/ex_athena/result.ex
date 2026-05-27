defmodule ExAthena.Result do
  @moduledoc """
  Canonical run outcome returned by `ExAthena.run/2` and
  `ExAthena.Loop.run/2`.

  Carries the terminal state plus full accounting so consumers can drive
  retries, billing, and observability off a single uniform shape. Every
  termination — success OR error — produces a `Result`, including the
  caps (`:error_max_turns`, `:error_max_budget_usd`, …).

  ## Fields

    * `:text` — the assistant's final text (may be empty for error
      terminations).
    * `:messages` — the full conversation thread.
    * `:finish_reason` — a `ExAthena.Loop.Terminations.subtype/0`. See that
      module for the enumeration and category helpers.
    * `:halted_reason` — the `:halt` payload when `finish_reason` is
      `:error_halted`; `nil` otherwise.
    * `:iterations` — number of completed loop iterations.
    * `:tool_calls_made` — total tool calls executed across all iterations.
    * `:usage` — aggregated token usage `%{input_tokens:, output_tokens:,
      total_tokens:}` or nil if the provider didn't report.
    * `:cost_usd` — aggregated cost in USD, nil if unknown.
    * `:duration_ms` — wall-clock time from `ExAthena.run/2` entry to
      termination.
    * `:model` — the model identifier as reported by the provider.
    * `:provider` — the provider atom / module that served the run.
    * `:error_diagnostic` — structured validation failure payload when
      `finish_reason` is `:error_schema_validation`; `nil` otherwise. Shape:
      `%{schema: term(), received: String.t() | nil, violations: [%{reason: String.t()}]}`.
    * `:deliverable` — the payload passed to the `finish` tool when
      `finish_reason` is `:submitted`; `nil` for all other terminations.
      Carries the model's declared output (summary, plan text, or any
      value the `finish` tool received).
    * `:telemetry` — span metadata summarising OTel attrs for the run
      (Phase 4).
    * `:no_progress_snapshot` — the last few message pairs (assistant +
      tool results) captured when `finish_reason` is `:error_no_progress`.
      `nil` for all other terminations.
  """

  alias ExAthena.Loop.Terminations
  alias ExAthena.Messages.Message

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer()
        }

  @type error_diagnostic :: %{
          schema: term(),
          received: String.t() | nil,
          violations: [%{reason: String.t()}]
        }

  defstruct text: nil,
            messages: [],
            finish_reason: :stop,
            halted_reason: nil,
            error_diagnostic: nil,
            deliverable: nil,
            iterations: 0,
            tool_calls_made: 0,
            usage: nil,
            cost_usd: nil,
            duration_ms: nil,
            model: nil,
            provider: nil,
            telemetry: %{},
            no_progress_snapshot: nil

  @type t :: %__MODULE__{
          text: String.t() | nil,
          messages: [Message.t()],
          finish_reason: Terminations.subtype(),
          halted_reason: term() | nil,
          error_diagnostic: error_diagnostic() | nil,
          deliverable: term() | nil,
          iterations: non_neg_integer(),
          tool_calls_made: non_neg_integer(),
          usage: usage() | nil,
          cost_usd: float() | nil,
          duration_ms: non_neg_integer() | nil,
          model: String.t() | nil,
          provider: atom() | module() | nil,
          telemetry: map(),
          no_progress_snapshot: [Message.t()] | nil
        }

  @doc "Whether the run finished normally (no error termination)."
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{finish_reason: r}), do: Terminations.success?(r)

  @doc "Whether the run ended with an error termination."
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{finish_reason: r}), do: Terminations.error?(r)

  @doc "Shortcut for `ExAthena.Loop.Terminations.category/1` on this Result."
  @spec category(t()) :: :success | :retryable | :capacity | :fatal
  def category(%__MODULE__{finish_reason: r}), do: Terminations.category(r)
end
