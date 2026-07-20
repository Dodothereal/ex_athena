defmodule ExAthena.ModelListing do
  @moduledoc """
  Enumerates the models a backend can serve, normalised to `ExAthena.Model`.

  This is the single place that knows how each family of backend answers "what
  models do you have?". It exists as its own module rather than inside
  `ExAthena.Providers.ReqLLM` because listing shares nothing with inference: it
  speaks different endpoints, on different paths, with different failure
  tolerances.

  ## Why the transport is hand-rolled

  Neither `req_llm` nor `llm_db` can enumerate a live server. `req_llm` ships no
  discovery callback and no adapter that issues `GET /v1/models`; its
  `ReqLLM.available_models/1` is a *catalog* query (llm_db candidates filtered by
  which credentials happen to resolve), and llm_db is a build-time snapshot with
  no runtime HTTP at all. Neither has any notion of a local Ollama daemon — the
  catalog carries `ollama_cloud`, never `localhost:11434`. So live enumeration is
  ours to do, and the catalog is used for what it is genuinely good at: metadata.

  ## Dispatch

  | Backend | Source |
  |---|---|
  | `:ollama` | `GET /api/tags` on the bare host, optionally plus the cloud catalogue |
  | `:llamacpp` | `GET /v1/models` |
  | `:exo` | `GET /v1/models?status=downloaded` |
  | any other tag with a `base_url` | `GET /v1/models` (OpenAI wire format) |
  | any other tag | the llm_db catalog for that provider |

  Local backends are matched on `:openai_compatible_backend` rather than on
  `:req_llm_provider_tag`, because every OpenAI-wire backend — Ollama and
  llama.cpp included — carries the tag `"openai"`; the tag cannot tell them apart.
  """

  alias ExAthena.{Error, Model}

  @default_timeout_ms 2_000
  @default_cloud_base_url "https://ollama.com"

  @doc """
  List the models available for the backend described by `opts`.

  `opts` are the provider opts `ExAthena.Config` already threads for a call —
  `:base_url`, `:api_key`, `:req_llm_provider_tag`, `:openai_compatible_backend`,
  `:extra_headers` — plus:

    * `:timeout_ms` — per-request receive timeout (default 2_000). Listing backs
      a UI picker, so it fails fast rather than hanging the interface.
    * `:include_cloud` — Ollama only; also fetch the `ollama.com` catalogue.
    * `:cloud_base_url` — Ollama cloud host override (default `https://ollama.com`).
  """
  @spec list(keyword()) :: {:ok, [Model.t()]} | {:error, Error.t()}
  def list(opts \\ []) do
    case Keyword.get(opts, :openai_compatible_backend) do
      :ollama -> list_ollama(opts)
      :llamacpp -> list_openai_compatible(:llamacpp, opts, [])
      :exo -> list_openai_compatible(:exo, opts, status: "downloaded")
      _ -> list_by_tag(opts)
    end
  end

  @doc """
  Reduce a listing result to the bare sorted ids / error atoms that the
  deprecated `ExAthena.Chat.*` helpers promised.

  Lives here, next to the errors it decodes, so the three shims share one
  translation instead of re-deriving it — the canonical `ExAthena.Error` keeps
  the original atom in `:raw` for exactly this purpose.
  """
  @spec legacy_result({:ok, [Model.t()]} | {:error, Error.t()}) ::
          {:ok, [String.t()]} | {:error, atom() | {:http, integer()}}
  def legacy_result({:ok, models}), do: {:ok, models |> Enum.map(& &1.id) |> Enum.sort()}

  def legacy_result({:error, %Error{status: status}}) when is_integer(status),
    do: {:error, {:http, status}}

  def legacy_result({:error, %Error{raw: raw}}) when is_atom(raw) and not is_nil(raw),
    do: {:error, raw}

  def legacy_result({:error, _}), do: {:error, :unexpected_response}

  # ── Ollama ────────────────────────────────────────────────────────
  #
  # The local daemon speaks its own `/api/tags`, which lives on the bare host
  # rather than under the `/v1` prefix ExAthena appends for chat. The cloud
  # catalogue is the same endpoint on ollama.com (unauthenticated), and its
  # names are only invocable through a signed-in local daemon once suffixed
  # `-cloud`, so the suffix is applied here rather than left to every caller.

  defp list_ollama(opts) do
    with {:ok, local} <- fetch_tags(base_host(opts), :ollama, opts) do
      {:ok, Enum.sort_by(local ++ cloud_models(opts), & &1.id)}
    end
  end

  defp cloud_models(opts) do
    if Keyword.get(opts, :include_cloud, false) do
      cloud_base =
        opts
        |> Keyword.get(:cloud_base_url, @default_cloud_base_url)
        |> strip_v1_suffix()

      # A caller that asked for cloud models still wants the local ones it can
      # actually run: a down or unreachable ollama.com must not blank the picker.
      case fetch_tags(cloud_base, :ollama, opts) do
        {:ok, models} -> Enum.map(models, &to_cloud_model/1)
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp to_cloud_model(%Model{id: id} = model) do
    cloud_id = if String.ends_with?(id, "-cloud"), do: id, else: id <> "-cloud"
    %{model | id: cloud_id, name: cloud_id}
  end

  defp fetch_tags(base, provider, opts) do
    with {:ok, body} <- get(base <> "/api/tags", provider, opts),
         {:ok, names} <- decode_list(body, "models", "name") do
      {:ok, Enum.map(names, &enrich(build_model(&1, provider, :server), :ollama_cloud))}
    end
  end

  # ── OpenAI-wire listing ───────────────────────────────────────────

  defp list_openai_compatible(provider, opts, params) do
    url = base_host(opts) <> "/v1/models" <> encode_params(params)

    with {:ok, body} <- get(url, provider, opts),
         {:ok, ids} <- decode_list(body, "data", "id") do
      {:ok, Enum.map(ids, &build_model(&1, provider, :server))}
    end
  end

  defp encode_params([]), do: ""
  defp encode_params(params), do: "?" <> URI.encode_query(params)

  # ── Tag-driven providers ──────────────────────────────────────────
  #
  # A tag with a base_url is a remote OpenAI-wire endpoint (OpenAI itself,
  # OpenRouter, any user-registered compatible provider): ask it, because a
  # live account's model list is narrower and fresher than the catalog. Without
  # one there is nothing to ask — Anthropic and Google publish no list endpoint
  # ExAthena is configured for — so the catalog answers instead.

  defp list_by_tag(opts) do
    tag = Keyword.get(opts, :req_llm_provider_tag)

    case provider_atom(tag) do
      {:ok, provider} ->
        list_for_provider(provider, opts)

      :error ->
        {:error,
         Error.new(
           :capability,
           "cannot list models for provider tag #{inspect(tag)}: unknown to the llm_db catalog " <>
             "and no base_url to enumerate",
           raw: tag
         )}
    end
  end

  defp list_for_provider(provider, opts) do
    if Keyword.get(opts, :base_url) do
      with {:ok, models} <- list_openai_compatible(provider, opts, []) do
        {:ok, Enum.map(models, &enrich(&1, provider))}
      end
    else
      {:ok, catalog_models(provider)}
    end
  end

  defp catalog_models(provider) do
    provider
    |> LLMDB.models()
    |> Enum.reject(& &1.retired)
    |> Enum.map(fn %LLMDB.Model{} = model ->
      %Model{
        id: model.provider_model_id || model.id,
        name: model.name || model.id,
        provider: provider,
        context_window: limit(model, :context),
        max_output_tokens: limit(model, :output),
        source: :catalog,
        raw: model
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  # `String.to_existing_atom/1` keeps an attacker-supplied provider name in a
  # registry JSON spec from growing the atom table; llm_db has already
  # materialised every real provider atom by the time we run.
  defp provider_atom(tag) when is_binary(tag) and tag != "" do
    atom = String.to_existing_atom(tag)
    if LLMDB.models(atom) == [], do: :error, else: {:ok, atom}
  rescue
    ArgumentError -> :error
  end

  defp provider_atom(_), do: :error

  # ── Normalisation ─────────────────────────────────────────────────

  defp build_model(id, provider, source) do
    %Model{id: id, name: id, provider: provider, source: source}
  end

  # Local servers report an id and nothing else, so the catalog fills in what
  # it knows. A miss is left as nil: a wrong context window mis-sizes
  # compaction, which fails quietly and destructively.
  defp enrich(%Model{id: id} = model, catalog_provider) do
    case LLMDB.model(catalog_provider, id) do
      {:ok, %LLMDB.Model{} = found} ->
        %{
          model
          | name: found.name || model.name,
            context_window: limit(found, :context),
            max_output_tokens: limit(found, :output)
        }

      _ ->
        model
    end
  end

  defp limit(%LLMDB.Model{limits: limits}, key) do
    case (limits || %{})[key] do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  # ── Transport ─────────────────────────────────────────────────────

  defp get(url, provider, opts) do
    timeout = Keyword.get(opts, :timeout_ms) || @default_timeout_ms

    case Req.get(url, headers: headers(opts), receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.new(Error.from_status(status), "HTTP #{status} listing models at #{url}",
           provider: provider,
           status: status
         )}

      {:error, _reason} ->
        # The legacy per-backend atoms (`:ollama_unreachable`, …) live on in
        # `:raw` so the deprecated `ExAthena.Chat.*` wrappers can still return
        # exactly what their callers matched on before this consolidation.
        {:error,
         Error.new(:transport, "#{provider} is unreachable at #{url}",
           provider: provider,
           raw: :"#{provider}_unreachable"
         )}
    end
  end

  defp headers(opts) do
    extra =
      case Keyword.get(opts, :extra_headers) do
        map when is_map(map) -> Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)
        _ -> []
      end

    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> [{"authorization", "Bearer #{key}"} | extra]
      _ -> extra
    end
  end

  defp decode_list(body, list_key, id_key) when is_map(body) do
    case Map.get(body, list_key) do
      list when is_list(list) ->
        ids =
          list
          |> Enum.map(&Map.get(&1, id_key))
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, ids}

      _ ->
        {:error, unexpected_response()}
    end
  end

  defp decode_list(body, list_key, id_key) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_list(decoded, list_key, id_key)
      {:error, _} -> {:error, unexpected_response()}
    end
  end

  defp decode_list(_body, _list_key, _id_key), do: {:error, unexpected_response()}

  defp unexpected_response do
    Error.new(:server_error, "model listing response was not in the expected shape",
      raw: :unexpected_response
    )
  end

  # ExAthena appends `/v1` to a local base_url for chat, but the listing
  # endpoints are defined relative to the bare host.
  defp base_host(opts) do
    opts
    |> Keyword.get(:base_url)
    |> Kernel.||("")
    |> strip_v1_suffix()
  end

  defp strip_v1_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end
end
