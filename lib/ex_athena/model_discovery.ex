defmodule ExAthena.ModelDiscovery do
  @moduledoc """
  Generic HTTP-based model listing backed by an ETS TTL cache.

  Reads the `model_discovery` block from a `ProviderSpec` and fetches the
  list of available model IDs from the provider's API endpoint. Results are
  cached in an ETS table for `ttl_seconds` (default: 300) before re-fetching.

  ## model_discovery block

  ```json
  {
    "url": "https://openrouter.ai/api/v1/models",
    "path": "data.id",
    "headers": {"Authorization": "Bearer sk-or-..."},
    "ttl_seconds": 300
  }
  ```

  | Field        | Required | Description |
  |---|---|---|
  | `url`        | yes      | HTTP GET endpoint that returns model metadata |
  | `path`       | no       | Dot-delimited path into the JSON response to extract IDs (default: `"data.id"`) |
  | `headers`    | no       | Additional request headers (e.g. auth) |
  | `ttl_seconds`| no       | Cache lifetime in seconds (default: `300`) |

  ## Path extraction

  `path` is a dot-delimited string. Traversal descends through map keys; when a
  list is encountered the remaining path is applied to each element and results
  are flattened. Examples:

    * `"data.id"` — extracts `resp["data"][*]["id"]`
    * `"id"` — extracts `resp[*]["id"]` when the root is a list
    * `""` — returns root list elements (when they are strings)
  """

  use GenServer

  require Logger

  alias ExAthena.ProviderSpec

  @table :ex_athena_model_discovery_cache
  @default_ttl_seconds 300
  @default_path "data.id"

  # ── Public API ────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the list of available model IDs for the provider described by `spec`.

  Returns `{:ok, [String.t()]}` from the ETS cache when a fresh entry exists,
  or fetches from the provider's `model_discovery.url` and caches the result.

  Returns `{:error, :no_model_discovery}` when `spec.model_discovery` is `nil`.
  """
  @spec list_models(ProviderSpec.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(%ProviderSpec{model_discovery: nil}) do
    {:error, :no_model_discovery}
  end

  def list_models(%ProviderSpec{name: name, model_discovery: disc} = spec) when is_map(disc) do
    ttl_ms = Map.get(disc, "ttl_seconds", @default_ttl_seconds) * 1_000

    cached(name, ttl_ms, fn -> fetch(spec, disc) end)
  end

  @doc """
  Memoise `fun`'s successful result under `key` for `ttl_ms`.

  This is the cache behind every kind of model listing in ExAthena — the
  `ProviderSpec` fetch above and the live endpoint enumeration in
  `ExAthena.ModelListing` both land here, so there is exactly one table, one
  TTL policy and one thing to clear in tests.

  Only `{:ok, _}` is stored. Caching an error would turn a momentarily
  unreachable local daemon into an empty model picker for the rest of the TTL,
  which reads as "you have no models" rather than "I could not reach it".

  Pass `:no_cache` as the TTL to force a fresh computation (and refresh the
  entry) — a user hitting "reload models" means it.
  """
  @spec cached(term(), non_neg_integer() | :no_cache, (-> result)) :: result when result: term()
  def cached(key, ttl_ms, fun) when is_function(fun, 0) do
    now_ms = :erlang.monotonic_time(:millisecond)

    with true <- ttl_ms != :no_cache,
         {:ok, value} <- cache_lookup(key, now_ms, ttl_ms) do
      {:ok, value}
    else
      _ -> compute_and_cache(key, fun, now_ms)
    end
  end

  defp compute_and_cache(key, fun, now_ms) do
    case fun.() do
      {:ok, value} = ok ->
        :ets.insert(@table, {key, value, now_ms})
        ok

      other ->
        other
    end
  end

  @doc false
  def clear_cache do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  @spec extract_models(term(), String.t()) :: [String.t()]
  def extract_models(body, path) when is_binary(path) and path != "" do
    segments = String.split(path, ".")
    extract_by_path(body, segments)
  end

  def extract_models(body, _path) when is_list(body) do
    Enum.filter(body, &is_binary/1)
  end

  def extract_models(_, _), do: []

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  # ── Private helpers ───────────────────────────────────────────────

  defp cache_lookup(name, now_ms, ttl_ms) do
    case :ets.lookup(@table, name) do
      [{^name, models, fetched_at}] when now_ms - fetched_at < ttl_ms ->
        {:ok, models}

      _ ->
        :miss
    end
  end

  defp fetch(%ProviderSpec{name: name} = spec, disc) do
    case Map.fetch(disc, "url") do
      :error ->
        {:error, :missing_url}

      {:ok, url} ->
        raw_headers = Map.get(disc, "headers", %{})
        path = Map.get(disc, "path", @default_path)
        header_list = Enum.map(raw_headers, fn {k, v} -> {k, v} end)
        auth_headers = build_auth_headers(spec)

        case Req.get(url, headers: header_list ++ auth_headers) do
          {:ok, %{status: 200, body: body}} ->
            {:ok, extract_models(body, path)}

          {:ok, %{status: status}} ->
            Logger.warning("[ModelDiscovery] HTTP #{status} fetching models for #{inspect(name)}")
            {:error, {:http_error, status}}

          {:error, reason} ->
            Logger.warning(
              "[ModelDiscovery] fetch error for #{inspect(name)}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp build_auth_headers(%ProviderSpec{api_key: key}) when is_binary(key) and key != "" do
    [{"authorization", "Bearer #{key}"}]
  end

  defp build_auth_headers(%ProviderSpec{api_key_env: env_var})
       when is_binary(env_var) and env_var != "" do
    case System.get_env(env_var) do
      nil -> []
      key -> [{"authorization", "Bearer #{key}"}]
    end
  end

  defp build_auth_headers(_), do: []

  defp extract_by_path(data, []) when is_binary(data), do: [data]
  defp extract_by_path(data, []) when is_list(data), do: Enum.filter(data, &is_binary/1)
  defp extract_by_path(_data, []), do: []

  defp extract_by_path(data, [key | rest]) when is_map(data) do
    case Map.get(data, key) do
      nil -> []
      value -> extract_by_path(value, rest)
    end
  end

  defp extract_by_path(list, path) when is_list(list) do
    Enum.flat_map(list, &extract_by_path(&1, path))
  end

  defp extract_by_path(_data, _path), do: []
end
