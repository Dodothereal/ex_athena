defmodule ExAthena.Embedding do
  @moduledoc """
  A normalised embeddings response.

  `:embeddings` is **always** a list of vectors, one per input — even when the
  caller embedded a single string. Indexing jobs feed hundreds of chunks
  through one call and zip the result back onto their inputs, so a shape that
  changes with the arity of the input would force every caller to branch.

  `:usage` carries token accounting when the provider reports it (embedding
  endpoints only bill input tokens), and `:raw` keeps the provider's original
  payload for debugging.
  """

  defstruct [:embeddings, :model, :provider, :usage, :raw]

  @type vector :: [float()]

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          embeddings: [vector()],
          model: String.t() | nil,
          provider: atom() | module() | nil,
          usage: usage() | nil,
          raw: term() | nil
        }
end
