defmodule ExAthena.Config do
  @moduledoc """
  Resolves the provider and per-call options for an ExAthena request.

  Resolution order (per key, highest to lowest priority):

    1. `opts[:key]` — per-call override always wins.
    2. For atom-named providers: `Application.get_env(:ex_athena, provider)[:key]`
       — provider-specific `config.exs` entry.
       For string-named providers: the matching JSON file loaded from
       `~/.config/ex_athena/providers/` by `ExAthena.ProviderRegistry`.
    3. `Application.get_env(:ex_athena, :key)` — top-level library config.
    4. Provider default (if the provider declares one).

  Matches the `stripity_stripe` / `ex_aws` pattern: per-call overrides win,
  application config is the default, no global mutable state.

  String provider names (e.g. `provider: "my-groq"`) are resolved through
  `ExAthena.ProviderRegistry`, which loads `*.json` files from
  `~/.config/ex_athena/providers/` at application startup. See the
  [Providers guide](guides/providers.md) for the full JSON schema, security
  notes, and ready-to-copy examples.

  ## Known providers

  | Atom | Module |
  |---|---|
  | `:ollama` | `ExAthena.Providers.ReqLLM` |
  | `:openai_compatible` | `ExAthena.Providers.ReqLLM` |
  | `:openai` | `ExAthena.Providers.ReqLLM` |
  | `:llamacpp` | `ExAthena.Providers.ReqLLM` |
  | `:claude` | `ExAthena.Providers.ReqLLM` |
  | `:anthropic` | `ExAthena.Providers.ReqLLM` |
  | `:gemini` | `ExAthena.Providers.ReqLLM` |
  | `:openrouter` | `ExAthena.Providers.ReqLLM` |
  | `:req_llm` | `ExAthena.Providers.ReqLLM` |
  | `:mock` | `ExAthena.Providers.Mock` |

  You may also pass any module that implements `ExAthena.Provider` directly, or
  define custom providers by placing JSON files in `~/.config/ex_athena/providers/`
  (loaded at startup by `ExAthena.ProviderRegistry`).

  ## Request queue

  `ExAthena.RequestQueue` is an opt-in semaphore that caps concurrent in-flight
  requests per provider. Enable it with:

      config :ex_athena, :request_queue, enabled: true

  Per-provider depth limits can be set inside provider config blocks:

      config :ex_athena, :ollama, request_queue: [max_depth: 3]

  A global `max_depth` applies to all providers that don't have a per-provider
  override:

      config :ex_athena, :request_queue, enabled: true, max_depth: 5

  Built-in defaults (used when no application config is set):

  | Provider | Default max_depth |
  |---|---|
  | `:ollama` | 1 |
  | `:llamacpp` | 1 |
  | `:exo` | 1 |
  | `:openai`, `:anthropic`, `:claude`, `:gemini`, `:openrouter`, `:req_llm` | 10 |
  | unknown | 10 |

  Local providers deliberately default to a single slot until the serving
  setup is load-tested — raise at runtime via
  `set_request_queue_max_depth/2` (the hosts expose this next to the
  provider selector).
  """

  @request_queue_defaults %{
    ollama: 1,
    llamacpp: 1,
    exo: 1,
    openai: 10,
    openai_compatible: 10,
    anthropic: 10,
    claude: 10,
    gemini: 10,
    openrouter: 10,
    req_llm: 10,
    mock: 10
  }

  @builtin_providers %{
    ollama: ExAthena.Providers.ReqLLM,
    openai: ExAthena.Providers.ReqLLM,
    openai_compatible: ExAthena.Providers.ReqLLM,
    llamacpp: ExAthena.Providers.ReqLLM,
    claude: ExAthena.Providers.ReqLLM,
    anthropic: ExAthena.Providers.ReqLLM,
    gemini: ExAthena.Providers.ReqLLM,
    openrouter: ExAthena.Providers.ReqLLM,
    mock: ExAthena.Providers.Mock,
    req_llm: ExAthena.Providers.ReqLLM,
    claude_code: ExAthena.Providers.ClaudeCode,
    exo: ExAthena.Providers.ReqLLM
  }

  # Map the ExAthena provider atom → the `req_llm` provider tag that belongs
  # in the `"tag:model-id"` spec. When an ExAthena caller says `:ollama`, the
  # ReqLLM adapter turns a raw `model: "qwen3-coder"` into `"openai:qwen3-coder"`.
  #
  # Local Ollama and llama.cpp expose OpenAI-compatible APIs and have no
  # entries in req_llm's llm_db catalog, so they must route through the
  # `:openai` tag with a custom base_url. See `req_llm/guides/ollama.md`.
  @req_llm_provider_tag %{
    ollama: "openai",
    openai: "openai",
    openai_compatible: "openai",
    llamacpp: "openai",
    claude: "anthropic",
    anthropic: "anthropic",
    gemini: "google",
    openrouter: "openai",
    exo: "openai"
  }

  # Provider atoms that talk to a local OpenAI-compatible server. These
  # 1) need `/v1` appended to base_url if the caller didn't, and
  # 2) get `openai_compatible_backend: <atom>` so req_llm's openai adapter
  #    allows missing API keys (unauthenticated local deployments).
  @local_openai_compatible_backends %{
    ollama: :ollama,
    llamacpp: :llamacpp,
    exo: :exo
  }

  # Built-in provider specs for first-class cloud providers that need a fixed
  # base_url + API-key env + model discovery but ship without a user JSON file.
  # A user spec of the same name in the ProviderRegistry always overrides these
  # (see provider_spec/1). OpenRouter is OpenAI wire-compatible, so it routes
  # through the `:openai` req_llm tag against its own base_url + bearer key.
  @builtin_specs %{
    "openrouter" => %ExAthena.ProviderSpec{
      name: "openrouter",
      adapter: :req_llm,
      module: ExAthena.Providers.ReqLLM,
      req_llm_provider_tag: "openai",
      base_url: "https://openrouter.ai/api/v1",
      api_key_env: "OPENROUTER_API_KEY",
      display_name: "OpenRouter",
      default_model: "openrouter/auto",
      model_discovery: %{
        "url" => "https://openrouter.ai/api/v1/models",
        "path" => "data.id",
        "ttl_seconds" => 300
      }
    }
  }

  @doc """
  Pop `:provider` from opts and return `{provider_module, remaining_opts}`.

  Raises `ArgumentError` if no provider is set in opts or in application env.

  For registry-loaded providers the following spec fields are threaded into opts
  using `Keyword.put_new/3` so per-call overrides always win:

    * `:req_llm_provider_tag` — from `spec.req_llm_provider_tag`
    * `:base_url` — from `spec.base_url`
    * `:extra_headers` — from `spec.extra_headers` (non-empty maps only)
    * `:api_key` — from `spec.api_key`, or resolved from `spec.api_key_env`
  """
  @spec pop_provider!(keyword()) :: {module(), keyword()}
  def pop_provider!(opts) do
    {provider, rest} = Keyword.pop(opts, :provider)

    provider =
      provider || Application.get_env(:ex_athena, :default_provider) ||
        raise ArgumentError,
              "no :provider passed and no :default_provider configured. " <>
                "Pass [provider: :ollama, ...] or set " <>
                "`config :ex_athena, default_provider: :ollama`."

    rest =
      case req_llm_provider_tag(provider) do
        nil -> rest
        tag -> Keyword.put_new(rest, :req_llm_provider_tag, tag)
      end

    rest =
      case Map.get(@local_openai_compatible_backends, provider) do
        nil -> rest
        backend -> Keyword.put_new(rest, :openai_compatible_backend, backend)
      end

    rest =
      case provider_spec(provider) do
        {:ok, spec} -> thread_registry_spec_opts(rest, spec)
        :error -> rest
      end

    {provider_module(provider), rest}
  end

  @doc """
  Resolve a provider's `ProviderSpec`. A user-registered JSON spec (loaded by
  `ExAthena.ProviderRegistry`) wins; otherwise a built-in spec (e.g. OpenRouter)
  is returned. Returns `:error` when neither exists.
  """
  @spec provider_spec(atom() | String.t()) :: {:ok, ExAthena.ProviderSpec.t()} | :error
  def provider_spec(provider) do
    case registry_lookup(provider) do
      {:ok, spec} -> {:ok, spec}
      :error -> Map.fetch(@builtin_specs, to_string(provider))
    end
  end

  defp thread_registry_spec_opts(opts, spec) do
    opts
    |> maybe_put_new(:base_url, spec.base_url)
    |> maybe_put_new(:api_key, resolve_spec_api_key(spec))
    |> maybe_put_new(:extra_headers, non_empty_headers(spec.extra_headers))
  end

  defp maybe_put_new(opts, _key, nil), do: opts
  defp maybe_put_new(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp non_empty_headers(m) when is_map(m) and map_size(m) > 0, do: m
  defp non_empty_headers(_), do: nil

  defp resolve_spec_api_key(%{api_key: key}) when is_binary(key) and key != "", do: key

  defp resolve_spec_api_key(%{api_key_env: env_var})
       when is_binary(env_var) and env_var != "" do
    System.get_env(env_var)
  end

  defp resolve_spec_api_key(_), do: nil

  @doc """
  Translate an ExAthena provider atom into the `req_llm` provider tag used in
  `"tag:model-id"` specs. Returns `nil` when the atom doesn't map to req_llm
  (e.g. `:mock`, or a user-supplied module).

  Resolution order: a registry-loaded JSON spec wins (its `req_llm_provider_tag`
  field), with the static built-in map as fallback when no spec is loaded for
  the atom or the spec's tag is unset. This matters when a JSON-defined
  provider's name collides with a built-in atom (e.g. `:openrouter`, which is
  also present in the built-in map for `config.exs` users) — the user's JSON
  file is authoritative.
  """
  @spec req_llm_provider_tag(atom() | module()) :: String.t() | nil
  def req_llm_provider_tag(atom) when is_atom(atom) do
    case registry_lookup(atom) do
      {:ok, %{req_llm_provider_tag: tag}} when is_binary(tag) and tag != "" ->
        tag

      _ ->
        Map.get(@req_llm_provider_tag, atom)
    end
  end

  def req_llm_provider_tag(_), do: nil

  @doc """
  Resolve a provider atom (or module) to its implementing module.

  Resolution order:
    1. Built-in provider map (compile-time constant, fastest path).
    2. `ExAthena.ProviderRegistry` — for providers loaded from JSON config files.
    3. Module check — accepts any atom that is a loaded module implementing
       `ExAthena.Provider`.
  """
  @spec provider_module(atom() | module()) :: module()
  def provider_module(mod) when is_atom(mod) do
    case Map.fetch(@builtin_providers, mod) do
      {:ok, module} ->
        module

      :error ->
        case registry_lookup(mod) do
          {:ok, spec} ->
            spec.module

          :error ->
            if Code.ensure_loaded?(mod) and function_exported?(mod, :capabilities, 0) do
              mod
            else
              raise ArgumentError,
                    "unknown provider: #{inspect(mod)}. Known: " <>
                      inspect(Map.keys(@builtin_providers)) <>
                      ", or pass a module implementing ExAthena.Provider."
            end
        end
    end
  end

  @doc false
  @spec builtin_providers() :: %{atom() => module()}
  def builtin_providers, do: @builtin_providers

  @doc """
  Return all known providers: built-in atoms plus any specs loaded by
  `ExAthena.ProviderRegistry`.

  Each entry is a map with:
    * `:name` — string name of the provider
    * `:module` — the implementing module
    * `:source` — `:builtin` or `:registry`
  """
  @spec list_providers() :: [
          %{
            name: String.t(),
            display_name: String.t(),
            module: module(),
            source: :builtin | :registry
          }
        ]
  def list_providers do
    builtin_entries =
      Enum.map(@builtin_providers, fn {atom, mod} ->
        name = Atom.to_string(atom)
        %{name: name, display_name: name, module: mod, source: :builtin}
      end)

    registry_entries =
      registry_list()
      |> Enum.map(fn spec ->
        %{
          name: spec.name,
          display_name: spec.display_name || spec.name,
          module: spec.module,
          source: :registry
        }
      end)

    builtin_entries ++ registry_entries
  end

  @doc """
  Look up a single configuration value for `provider_module` with the tiered
  resolution order. `opts` wins, then provider-specific config, then top-level
  config, then the supplied default.

  The provider atom is derived from the module name: `Providers.Ollama` → `:ollama`.
  """
  @spec get(module(), atom(), keyword(), term()) :: term()
  def get(provider_module, key, opts, default \\ nil) do
    Keyword.get(opts, key) ||
      get_provider_env(provider_module, key) ||
      Application.get_env(:ex_athena, key) ||
      default
  end

  @doc """
  Build the keyword list passed to a provider's `query/2` / `stream/3` callback.

  Flattens per-call overrides + application env for this provider into one
  keyword list. Providers use `Keyword.get/3` on the result.
  """
  @spec provider_opts(module(), keyword(), atom() | nil) :: keyword()
  def provider_opts(provider_module, opts, provider_atom \\ nil) do
    atom = provider_atom || Keyword.get(opts, :provider)
    app_env = provider_app_env(provider_module, atom)

    app_env
    |> Keyword.merge(opts)
    |> Keyword.delete(:provider)
  end

  # Every built-in provider atom (:ollama, :openai, :gemini, :claude, …) maps to
  # the SAME `ExAthena.Providers.ReqLLM` module. Accumulating config across all
  # of a module's atoms leaks instance-specific keys — most damagingly
  # `base_url` — from one provider into another (e.g. a configured Ollama
  # `base_url` would be sent on a Gemini request, 404ing against the wrong host).
  # When the concrete provider atom is known, read ONLY that atom's config.
  defp provider_app_env(_provider_module, atom)
       when is_atom(atom) and not is_nil(atom) and is_map_key(@builtin_providers, atom) do
    Application.get_env(:ex_athena, atom, [])
  end

  # Unknown atom / custom module: fall back to module-wide accumulation.
  defp provider_app_env(provider_module, _atom) do
    provider_module
    |> provider_atoms()
    |> Enum.flat_map(fn atom ->
      Application.get_env(:ex_athena, atom, [])
    end)
  end

  # A module may correspond to multiple atoms (OpenAICompatible covers
  # :openai, :openai_compatible, :llamacpp). We accumulate config from all
  # of them so users can write `config :ex_athena, :openai, api_key: "..."`.
  defp provider_atoms(provider_module) do
    @builtin_providers
    |> Enum.filter(fn {_atom, mod} -> mod == provider_module end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Resolve the embedding model for a provider.

  Order: per-call `:model` → per-call `:embedding_model` → the provider's
  `embedding_model:` config → the top-level `:embedding_model` config.
  Returns `nil` when none is set.

  Embedding models are a different population from chat models
  (`nomic-embed-text` vs `qwen3-coder`), so the provider's `model:` key is
  deliberately **not** a fallback — silently embedding with a chat model
  produces vectors that look fine and retrieve badly.
  """
  @spec embedding_model(atom() | module() | nil, keyword()) :: String.t() | nil
  def embedding_model(provider, opts) do
    Keyword.get(opts, :model) ||
      Keyword.get(opts, :embedding_model) ||
      provider_env(provider)[:embedding_model] ||
      Application.get_env(:ex_athena, :embedding_model)
  end

  defp provider_env(atom) when is_atom(atom) and not is_nil(atom),
    do: Application.get_env(:ex_athena, atom, [])

  defp provider_env(_), do: []

  @doc """
  Return the maximum concurrent request depth for `provider_atom`.

  Resolution order:
    1. `config :ex_athena, provider_atom, request_queue: [max_depth: N]`
    2. `config :ex_athena, :request_queue, max_depth: N`
    3. Built-in per-provider default (local providers: 1, cloud: 10).
    4. `10` for unrecognised providers.
  """
  @spec request_queue_max_depth(atom()) :: pos_integer()
  def request_queue_max_depth(provider_atom) when is_atom(provider_atom) do
    per_provider =
      :ex_athena
      |> Application.get_env(provider_atom, [])
      |> Keyword.get(:request_queue, [])
      |> Keyword.get(:max_depth)

    global =
      :ex_athena
      |> Application.get_env(:request_queue, [])
      |> Keyword.get(:max_depth)

    per_provider || global || Map.get(@request_queue_defaults, provider_atom, 10)
  end

  @doc """
  Set the per-provider concurrent-slot cap at runtime.

  Hosts expose this next to their provider selector so users can raise a
  local provider's slots once their serving setup proves it can take more
  load (everything local defaults to 1). Merges into the provider's existing
  application env, preserving keys like `base_url`.

  Takes effect on the next slot acquisition — in-flight holders and waiters
  are unaffected.
  """
  @spec set_request_queue_max_depth(atom(), pos_integer()) :: :ok | {:error, :invalid_depth}
  def set_request_queue_max_depth(provider_atom, depth)
      when is_atom(provider_atom) and is_integer(depth) and depth > 0 do
    provider_env = Application.get_env(:ex_athena, provider_atom, [])

    request_queue =
      provider_env
      |> Keyword.get(:request_queue, [])
      |> Keyword.put(:max_depth, depth)

    Application.put_env(
      :ex_athena,
      provider_atom,
      Keyword.put(provider_env, :request_queue, request_queue)
    )
  end

  def set_request_queue_max_depth(_provider_atom, _depth), do: {:error, :invalid_depth}

  @doc """
  Return `true` when the request queue feature is enabled.

  Enabled by default — local inference servers (ollama / llama.cpp / exo)
  can only serve 1-3 concurrent requests, and the per-call gate is what keeps
  concurrent loops and subagents from overwhelming them. Disable with:

      config :ex_athena, :request_queue, enabled: false
  """
  @spec request_queue_enabled?() :: boolean()
  def request_queue_enabled? do
    :ex_athena
    |> Application.get_env(:request_queue, [])
    |> Keyword.get(:enabled, true)
  end

  defp get_provider_env(provider_module, key) do
    provider_module
    |> provider_atoms()
    |> Enum.find_value(fn atom ->
      :ex_athena
      |> Application.get_env(atom, [])
      |> Keyword.get(key)
    end)
  end

  defp registry_lookup(name) when is_atom(name) do
    case Process.whereis(ExAthena.ProviderRegistry) do
      nil -> :error
      _pid -> ExAthena.ProviderRegistry.lookup(name)
    end
  end

  defp registry_list do
    case Process.whereis(ExAthena.ProviderRegistry) do
      nil -> []
      _pid -> ExAthena.ProviderRegistry.list()
    end
  end
end
