defmodule ExAthena.ContextWindow do
  @moduledoc false

  use GenServer

  @table :ex_athena_context_window_cache
  @timeout_ms 3_000

  @ollama_default "http://localhost:11434"
  @llamacpp_default "http://localhost:8080"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec lookup(keyword()) :: {:ok, pos_integer()} | :error
  def lookup(opts) do
    with backend when backend in [:ollama, :llamacpp] <-
           Keyword.get(opts, :openai_compatible_backend),
         model_raw when is_binary(model_raw) and model_raw != "" <-
           Keyword.get(opts, :model) do
      model = strip_provider_prefix(model_raw, Keyword.get(opts, :req_llm_provider_tag))
      base_url = resolve_base_url(opts, backend)
      key = {backend, base_url, model}

      case ets_lookup(key) do
        {:ok, _} = hit ->
          hit

        :miss ->
          try do
            GenServer.call(
              __MODULE__,
              {:fetch, backend, base_url, model, key},
              @timeout_ms + 1_000
            )
          catch
            :exit, _ -> :error
          end
      end
    else
      _ -> :error
    end
  end

  @impl GenServer
  def init(_) do
    ensure_table()
    {:ok, %{}}
  end

  # Blocking HTTP is intentional: this call happens at most once per
  # (backend, base_url, model) tuple across the process lifetime — subsequent
  # calls hit the ETS cache directly and never reach the GenServer. Serialising
  # through the GenServer also prevents duplicate HTTP requests when two callers
  # race on the same key. The 3 s HTTP timeout is well within the 4 s
  # GenServer call timeout set by the caller.
  @impl GenServer
  def handle_call({:fetch, backend, base_url, model, key}, _from, state) do
    case ets_lookup(key) do
      {:ok, _} = hit ->
        {:reply, hit, state}

      :miss ->
        result =
          case do_fetch(backend, base_url, model) do
            {:ok, ctx} ->
              :ets.insert(@table, {key, ctx})
              {:ok, ctx}

            :error ->
              :error
          end

        {:reply, result, state}
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end

  defp ets_lookup(key) do
    try do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :miss
      end
    rescue
      ArgumentError -> :miss
    end
  end

  defp do_fetch(:ollama, base_url, model), do: fetch_ollama(base_url, model)
  defp do_fetch(:llamacpp, base_url, _model), do: fetch_llamacpp(base_url)

  defp fetch_ollama(base_url, model) do
    url = strip_openai_suffix(base_url) <> "/api/show"

    case Req.post(url, json: %{"model" => model}, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        extract_ollama_context(body)

      {:ok, %Req.Response{}} ->
        :error

      {:error, _} ->
        :error
    end
  end

  defp fetch_llamacpp(base_url) do
    url = strip_openai_suffix(base_url) <> "/props"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"default_generation_settings" => %{"n_ctx" => n_ctx}}
          when is_integer(n_ctx) and n_ctx > 0 ->
            {:ok, n_ctx}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp extract_ollama_context(%{"model_info" => model_info}) when is_map(model_info) do
    case Enum.find_value(model_info, fn {k, v} ->
           if String.ends_with?(k, ".context_length") and is_integer(v) and v > 0, do: v
         end) do
      nil -> :error
      ctx -> {:ok, ctx}
    end
  end

  defp extract_ollama_context(_), do: :error

  defp resolve_base_url(opts, backend) do
    default =
      case backend do
        :ollama -> configured_ollama_url()
        :llamacpp -> configured_llamacpp_url()
      end

    strip_openai_suffix(Keyword.get(opts, :base_url, default))
  end

  defp configured_ollama_url do
    :ex_athena
    |> Application.get_env(:ollama, [])
    |> Keyword.get(:base_url, @ollama_default)
  end

  defp configured_llamacpp_url do
    :ex_athena
    |> Application.get_env(:llamacpp, [])
    |> Keyword.get(:base_url, @llamacpp_default)
  end

  defp strip_openai_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end

  defp strip_provider_prefix(model, nil), do: model

  defp strip_provider_prefix(model, tag) when is_binary(tag) do
    prefix = tag <> ":"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end
end
