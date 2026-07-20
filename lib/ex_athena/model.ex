defmodule ExAthena.Model do
  @moduledoc """
  A normalised entry in a provider's model list.

  Every backend describes its models differently — Ollama's `/api/tags` returns
  `{"models": [{"name": ...}]}`, OpenAI-compatible servers return
  `{"data": [{"id": ...}]}`, and cloud providers are only knowable from the
  llm_db catalog. Hosts building a model picker should not have to know which
  of those they are talking to, so listing always yields this struct.

  `:id` is the string to hand back as `model:` on a subsequent `ExAthena.query/2`
  — round-tripping it is the whole point of listing.

  `:context_window` is `nil` whenever it cannot be established honestly. Local
  servers do not report it and most local models are absent from the catalog;
  inventing a default here would silently mis-size compaction, so the absence is
  reported instead of guessed.

  `:source` records how the entry was obtained, because the two kinds carry
  different guarantees:

    * `:server` — enumerated live from the endpoint, so it is installed and
      ready to serve right now.
    * `:catalog` — read from the llm_db catalog. The model exists and the
      metadata is trustworthy, but nothing was contacted to confirm the
      caller's credentials can reach it.
  """

  defstruct [:id, :name, :provider, :context_window, :max_output_tokens, :source, :raw]

  @type source :: :server | :catalog

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          provider: atom() | nil,
          context_window: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          source: source() | nil,
          raw: term() | nil
        }
end
