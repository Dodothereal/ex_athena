defmodule ExAthena.Chat.Exo do
  @moduledoc """
  Talks to a local exo cluster's HTTP API (https://github.com/exo-explore/exo)
  for chat-time helpers.

  `list_models/1` hits `GET /v1/models?status=downloaded` and returns the model
  ids downloaded somewhere in the cluster, sorted alphabetically. exo model ids
  are full HuggingFace ids (e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit`).
  """

  @default_base_url "http://localhost:52415"
  @timeout_ms 2_000

  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :exo_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    base = opts |> Keyword.get(:base_url, configured_base_url()) |> strip_v1_suffix()
    url = base <> "/v1/models?status=downloaded"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_models(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, %Req.TransportError{}} -> {:error, :exo_unreachable}
      {:error, %Mint.TransportError{}} -> {:error, :exo_unreachable}
      {:error, _} -> {:error, :exo_unreachable}
    end
  end

  defp decode_models(%{"data" => list}) when is_list(list) do
    names =
      list
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    {:ok, names}
  end

  defp decode_models(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_models(decoded)
      {:error, _} -> {:error, :unexpected_response}
    end
  end

  defp decode_models(_), do: {:error, :unexpected_response}

  defp configured_base_url do
    :ex_athena
    |> Application.get_env(:exo, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp strip_v1_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end
end
