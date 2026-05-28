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

  You may also pass any module that implements `ExAthena.Provider` directly, or a
  string name matching a JSON-defined provider.

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
  | `:ollama` | 2 |
  | `:llamacpp` | 1 |
  | `:exo` | 3 |
  | `:openai`, `:anthropic`, `:claude`, `:gemini`, `:openrouter`, `:req_llm` | 10 |
  | unknown | 10 |
  """

  @request_queue_defaults %{
    ollama: 2,
    llamacpp: 1,
    exo: 3,
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
    req_llm: ExAthena.Providers.ReqLLM
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
    openrouter: "openai"
  }

  # Provider atoms that talk to a local OpenAI-compatible server. These
  # 1) need `/v1` appended to base_url if the caller didn't, and
  # 2) get `openai_compatible_backend: <atom>` so req_llm's openai adapter
  #    allows missing API keys (unauthenticated local deployments).
  @local_openai_compatible_backends %{
    ollama: :ollama,
    llamacpp: :llamacpp
  }

  @doc """
  Pop `:provider` from opts and return `{provider_module, remaining_opts}`.

  Raises `ArgumentError` if no provider is set in opts or in application env.
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

    {provider_module(provider), rest}
  end

  @doc """
  Translate an ExAthena provider atom into the `req_llm` provider tag used in
  `"tag:model-id"` specs. Returns `nil` when the atom doesn't map to req_llm
  (e.g. `:mock`, or a user-supplied module).
  """
  @spec req_llm_provider_tag(atom() | module()) :: String.t() | nil
  def req_llm_provider_tag(atom) when is_atom(atom),
    do: Map.get(@req_llm_provider_tag, atom)

  def req_llm_provider_tag(_), do: nil

  @doc "Resolve a provider atom (or module) to its implementing module."
  @spec provider_module(atom() | module()) :: module()
  def provider_module(mod) when is_atom(mod) do
    case Map.fetch(@builtin_providers, mod) do
      {:ok, module} ->
        module

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

  @doc false
  @spec builtin_providers() :: %{atom() => module()}
  def builtin_providers, do: @builtin_providers

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
  Return the maximum concurrent request depth for `provider_atom`.

  Resolution order:
    1. `config :ex_athena, provider_atom, request_queue: [max_depth: N]`
    2. `config :ex_athena, :request_queue, max_depth: N`
    3. Built-in per-provider default (ollama: 2, llamacpp: 1, exo: 3, cloud: 10).
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
  Return `true` when the request queue feature is enabled via application config.

  Opt-in: defaults to `false`. Enable with:

      config :ex_athena, :request_queue, enabled: true
  """
  @spec request_queue_enabled?() :: boolean()
  def request_queue_enabled? do
    :ex_athena
    |> Application.get_env(:request_queue, [])
    |> Keyword.get(:enabled, false)
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
end
