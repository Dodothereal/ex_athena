defmodule ExAthena.Chat.Ollama do
  @moduledoc """
  Deprecated shim over Ollama model listing.

  The `/api/tags` transport that used to live here now belongs to
  `ExAthena.ModelListing`, reached through the provider abstraction as
  `ExAthena.list_models(:ollama)`. Keeping the HTTP call in a chat-side helper
  meant every host that wanted a model picker had to know Ollama's wire
  format — which is exactly what downstream apps ended up re-implementing.

  These functions remain so existing callers keep working, and return the same
  sorted strings and error atoms they always did. New code should call
  `ExAthena.list_models/2`, which returns `ExAthena.Model` structs, reports
  context windows, and works for every provider rather than just this one.
  """

  alias ExAthena.ModelListing

  @default_base_url "http://localhost:11434"
  @default_cloud_base_url "https://ollama.com"
  @timeout_ms 2_000

  @deprecated "Use ExAthena.list_models(:ollama) instead"
  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :ollama_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    opts
    |> Keyword.get(:base_url, configured_base_url())
    |> list()
  end

  @doc """
  List the Ollama cloud catalog (`https://ollama.com/api/tags`), each name
  suffixed with `-cloud` for invocation via a signed-in local daemon.
  """
  @deprecated "Use ExAthena.list_models(:ollama, include_cloud: true) instead"
  @spec list_cloud_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :ollama_unreachable | :unexpected_response | {:http, integer()}}
  def list_cloud_models(opts \\ []) do
    # The cloud catalogue is the same endpoint and payload as a local daemon's,
    # just on another host — pointing the listing at it is the whole difference.
    opts
    |> Keyword.get(:cloud_base_url, @default_cloud_base_url)
    |> list()
    |> suffix_cloud()
  end

  defp list(base_url) do
    [
      openai_compatible_backend: :ollama,
      base_url: base_url,
      timeout_ms: @timeout_ms
    ]
    |> ModelListing.list()
    |> ModelListing.legacy_result()
  end

  defp suffix_cloud({:ok, names}) do
    {:ok, Enum.map(names, &if(String.ends_with?(&1, "-cloud"), do: &1, else: &1 <> "-cloud"))}
  end

  defp suffix_cloud(other), do: other

  defp configured_base_url do
    :ex_athena
    |> Application.get_env(:ollama, [])
    |> Keyword.get(:base_url, @default_base_url)
  end
end
