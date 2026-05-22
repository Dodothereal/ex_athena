defmodule ExAthena.Response do
  @moduledoc """
  A normalised inference response.

  `:text` is the concatenated assistant text. `:tool_calls` holds any tool
  calls the model wants the runtime to execute (empty when the model just
  replied with text). `:usage` carries token accounting when the provider
  reports it; `:raw` keeps the provider's original payload for debugging.
  """

  alias ExAthena.Messages.ToolCall

  defstruct [
    :text,
    :thinking,
    :tool_calls,
    :finish_reason,
    :usage,
    :model,
    :provider,
    :raw
  ]

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          text: String.t() | nil,
          thinking: String.t() | nil,
          tool_calls: [ToolCall.t()],
          finish_reason: :stop | :length | :tool_calls | :content_filter | :error | nil,
          usage: usage() | nil,
          model: String.t() | nil,
          provider: atom() | module() | nil,
          raw: term() | nil
        }
end
