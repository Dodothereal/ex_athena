defmodule ExAthena.Chat.LlamaCpp do
  @moduledoc """
  Deprecated shim over llama.cpp model listing.

  The `GET /v1/models` transport now lives in `ExAthena.ModelListing` and is
  reached as `ExAthena.list_models(:llamacpp)`, so that every backend is
  enumerated through one code path instead of one helper module per server.

  Retained for existing callers, returning the same sorted strings and error
  atoms as before. The llama.cpp server (`llama-server`) typically serves one
  model at a time, so the list usually has a single entry.
  """

  alias ExAthena.ModelListing

  @default_base_url "http://localhost:8080"
  @timeout_ms 2_000

  @deprecated "Use ExAthena.list_models(:llamacpp) instead"
  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :llamacpp_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    [
      openai_compatible_backend: :llamacpp,
      base_url: Keyword.get(opts, :base_url, configured_base_url()),
      timeout_ms: @timeout_ms
    ]
    |> ModelListing.list()
    |> ModelListing.legacy_result()
  end

  defp configured_base_url do
    :ex_athena
    |> Application.get_env(:llamacpp, [])
    |> Keyword.get(:base_url, @default_base_url)
  end
end
