defmodule ExAthena.Chat.Ollama do
  @moduledoc """
  Talks to a local Ollama daemon's native HTTP API for chat-time helpers.

  `list_models/1` hits the local daemon's `GET /api/tags` and returns the
  installed model names sorted alphabetically. `list_cloud_models/1` hits the
  same endpoint on `https://ollama.com` (the public cloud catalog — no auth
  required to list) and appends the `-cloud` suffix so each name is invocable
  through a signed-in local daemon (`ollama signin`), e.g. `glm-5.2` →
  `glm-5.2-cloud`. The tags endpoint lives on the bare host (not under `/v1`),
  so we strip the OpenAI prefix ExAthena adds internally.
  """

  @default_base_url "http://localhost:11434"
  @default_cloud_base_url "https://ollama.com"
  @timeout_ms 2_000

  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :ollama_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    base = opts |> Keyword.get(:base_url, configured_base_url()) |> strip_openai_suffix()

    with {:ok, body} <- get_tags(base), do: decode_models(body)
  end

  @doc """
  List the Ollama cloud catalog (`https://ollama.com/api/tags`), each name
  suffixed with `-cloud` for invocation via a signed-in local daemon.
  """
  @spec list_cloud_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :ollama_unreachable | :unexpected_response | {:http, integer()}}
  def list_cloud_models(opts \\ []) do
    base = opts |> Keyword.get(:cloud_base_url, @default_cloud_base_url) |> strip_openai_suffix()

    with {:ok, body} <- get_tags(base),
         {:ok, names} <- decode_models(body) do
      {:ok, Enum.map(names, &cloud_name/1)}
    end
  end

  defp get_tags(base) do
    url = base <> "/api/tags"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, %Req.TransportError{}} -> {:error, :ollama_unreachable}
      {:error, %Mint.TransportError{}} -> {:error, :ollama_unreachable}
      {:error, _} -> {:error, :ollama_unreachable}
    end
  end

  defp cloud_name(name) do
    if String.ends_with?(name, "-cloud"), do: name, else: name <> "-cloud"
  end

  defp decode_models(%{"models" => list}) when is_list(list) do
    names =
      list
      |> Enum.map(&Map.get(&1, "name"))
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
    |> Application.get_env(:ollama, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp strip_openai_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end
end
