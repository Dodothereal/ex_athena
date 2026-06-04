defmodule ExAthena.Provider do
  @moduledoc """
  Behaviour every provider must implement.

  A provider is a thin adapter between `ExAthena.Request` and a remote (or
  local) inference endpoint. It is expected to:

    1. Normalise the request into the provider's native wire format.
    2. Perform the HTTP call (or SDK call, for Claude).
    3. Parse the response (or stream) back into an `ExAthena.Response` /
       `ExAthena.Streaming.Event` sequence.
    4. Surface errors as `{:error, %ExAthena.Error{}}` tuples using the
       canonical kinds.

  ## Capabilities

  Each provider declares its capabilities statically. The loop uses these to
  decide the tool-call protocol and fallback strategy. See
  `ExAthena.Capabilities` for the shape.
  """

  alias ExAthena.{Capabilities, Request, Response, Streaming}

  @doc "Perform a one-shot request and return the final response."
  @callback query(Request.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Stream a request; `callback` is invoked with each `Streaming.Event`. Must
  still return `{:ok, final_response}` when the stream completes normally.
  """
  @callback stream(Request.t(), (Streaming.Event.t() -> term()), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc "Static capability map for this provider."
  @callback capabilities() :: Capabilities.t()

  @doc """
  Model-aware capability map. Receives the per-call opts (includes
  `:req_llm_provider_tag` and `:model`) so the provider can resolve
  the actual context window from a catalog (e.g. llm_db) and return
  a precise `max_tokens` instead of a static default.

  When not implemented, the loop falls back to `capabilities/0`.
  """
  @callback capabilities(opts :: keyword()) :: Capabilities.t()

  @doc """
  Lists the model identifiers this provider can serve, for UI selection.

  Returns `{:ok, [model_string]}` or `{:error, reason}`. Providers that cannot
  enumerate their models (the model is free-form) simply omit this callback; the
  UI then falls back to a free-text model input.
  """
  @callback list_models() :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks [stream: 3, capabilities: 1, list_models: 0]
end
