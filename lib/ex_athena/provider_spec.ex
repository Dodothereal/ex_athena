defmodule ExAthena.ProviderSpec do
  @moduledoc """
  Represents a provider loaded from a JSON file in the providers config directory.

  ## JSON format

  ```json
  {
    "name": "my-ollama",
    "adapter": "req_llm",
    "req_llm_provider_tag": "openai",
    "base_url": "http://localhost:11434/v1",
    "api_key": "optional",
    "default_model": "qwen3-coder",
    "metadata": {}
  }
  ```

  Required fields: `name`, `adapter`.
  Known adapters: `"req_llm"`, `"mock"`.
  """

  @known_adapters %{
    "req_llm" => ExAthena.Providers.ReqLLM,
    "mock" => ExAthena.Providers.Mock
  }

  @type t :: %__MODULE__{
          name: String.t(),
          adapter: atom(),
          module: module(),
          req_llm_provider_tag: String.t() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          default_model: String.t() | nil,
          metadata: map(),
          display_name: String.t() | nil,
          api_key_prompt: boolean(),
          api_key_env: String.t() | nil,
          extra_headers: map(),
          model_discovery: map() | nil
        }

  defstruct [
    :name,
    :adapter,
    :module,
    :req_llm_provider_tag,
    :base_url,
    :api_key,
    :default_model,
    :display_name,
    :api_key_env,
    :model_discovery,
    metadata: %{},
    api_key_prompt: false,
    extra_headers: %{}
  ]

  @doc """
  Parse a decoded JSON map into a `ProviderSpec`.

  Returns `{:ok, spec}` on success or `{:error, reason}` when required fields
  are missing or the adapter is not recognized.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(json) when is_map(json) do
    with {:ok, name} <- fetch_required_string(json, "name"),
         {:ok, adapter_str} <- fetch_required_string(json, "adapter"),
         {:ok, adapter, module} <- resolve_adapter(adapter_str) do
      spec = %__MODULE__{
        name: name,
        adapter: adapter,
        module: module,
        req_llm_provider_tag: Map.get(json, "req_llm_provider_tag"),
        base_url: Map.get(json, "base_url"),
        api_key: Map.get(json, "api_key"),
        default_model: Map.get(json, "default_model"),
        metadata: Map.get(json, "metadata", %{}),
        display_name: Map.get(json, "display_name"),
        api_key_prompt: Map.get(json, "api_key_prompt", false),
        api_key_env: Map.get(json, "api_key_env"),
        extra_headers: Map.get(json, "extra_headers", %{}),
        model_discovery: Map.get(json, "model_discovery")
      }

      {:ok, spec}
    end
  end

  @doc false
  @spec known_adapters() :: %{String.t() => module()}
  def known_adapters, do: @known_adapters

  defp fetch_required_string(json, key) do
    case Map.get(json, key) do
      nil -> {:error, "missing required field: #{key}"}
      "" -> {:error, "field #{inspect(key)} must not be empty"}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "field #{inspect(key)} must be a string"}
    end
  end

  defp resolve_adapter(adapter_str) do
    case Map.fetch(@known_adapters, adapter_str) do
      {:ok, module} ->
        {:ok, String.to_atom(adapter_str), module}

      :error ->
        known = Map.keys(@known_adapters) |> Enum.map(&inspect/1) |> Enum.join(", ")
        {:error, "unknown adapter: #{inspect(adapter_str)}. Known: #{known}"}
    end
  end
end
