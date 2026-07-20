defmodule ExAthena do
  @moduledoc """
  Provider-agnostic agent loop for Elixir.

  ExAthena runs against Ollama, OpenAI-compatible endpoints (OpenAI, OpenRouter,
  LM Studio, vLLM, and friends), llama.cpp, Google Gemini, or the Anthropic
  Claude API — with the same tools, hooks, permissions, and streaming semantics
  across every provider.

  ## Phase 1 surface (this release)

  Pure inference — `query/3` and `stream/3`. No tool execution, no agent loop
  yet (those ship in Phase 2 alongside `ExAthena.Tool`, `ExAthena.Loop`, and
  `ExAthena.Session`).

      ExAthena.query("Tell me a joke", provider: :ollama, model: "llama3.1")
      #=> {:ok, %ExAthena.Response{text: "…", …}}

  ## Configuring a default provider

      # config/config.exs
      config :ex_athena,
        default_provider: :ollama

      config :ex_athena, :ollama,
        base_url: "http://localhost:11434",
        model: "llama3.1"

      config :ex_athena, :openai_compatible,
        base_url: "https://api.openai.com/v1",
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini"

      config :ex_athena, :claude,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-opus-4-8"

      config :ex_athena, :gemini,
        api_key: System.get_env("GEMINI_API_KEY"),
        model: "gemini-2.5-flash"

  Per-call overrides always win:

      ExAthena.query("…", provider: :claude, model: "claude-sonnet-4-6")

  ## Runtime JSON providers

  You can define additional named providers without touching `config.exs` by
  dropping a JSON file into `~/.config/ex_athena/providers/`. Each file's
  `"name"` field becomes the string you pass as `provider:`:

      ExAthena.query("…", provider: "my-groq")
      ExAthena.query("…", provider: "my-groq", model: "mixtral-8x7b-32768")

  Files are loaded once at application startup via `ExAthena.ProviderRegistry`.
  Per-call opts still override JSON-file defaults. See the
  [Providers guide](guides/providers.md) for the full schema, security notes, and
  ready-to-copy examples for Groq, Together AI, Fireworks, and DeepSeek.

  ## Providers

  * `ExAthena.Providers.ReqLLM` — multi-backend via `req_llm`. Covers `:gemini`
    (Google Gemini), `:openai`, `:claude`/`:anthropic`, `:ollama`, and `:llamacpp`.
  * `ExAthena.Providers.Mock` — test double with scripted responses.

  Consumers can also pass a custom module that implements `ExAthena.Provider`, or
  define JSON-file providers as described above.

  ## Request queue

  A semaphore caps concurrent in-flight requests per provider (enabled by
  default — local inference servers can only serve 1-3 requests at a time).
  `query/2`, `stream/3`, and `extract_structured/2` acquire a slot per call;
  `run/2` acquires a slot around **each provider call inside the loop** (not
  one slot for the whole run), so concurrent agent loops and subagents
  interleave fairly on scarce GPU slots.

  Disable via:

      config :ex_athena, :request_queue, enabled: false

  Pass `queue: false` on any individual call to bypass the queue for that call.
  """

  alias ExAthena.{Config, Model, ModelDiscovery, Request, Response}
  alias ExAthena.RequestQueue

  @doc """
  One-shot inference. Returns the final `Response` struct with the full text.

  ## Options

    * `:provider` — provider atom (`:ollama`, `:openai_compatible`, `:claude`,
      `:gemini`, `:mock`), a module that implements `ExAthena.Provider`, or a
      string matching a JSON-defined provider loaded from
      `~/.config/ex_athena/providers/` (see the [Providers guide](guides/providers.md)).
      Defaults to `Application.get_env(:ex_athena, :default_provider)`.
    * `:model` — model name string. Defaults to the provider's configured model.
    * `:system_prompt` — optional system prompt string.
    * `:messages` — list of canonical messages; `prompt` is prepended as a user
      message if given.
    * `:max_tokens`, `:temperature`, `:top_p`, `:stop` — optional sampling knobs.
    * `:timeout_ms` — request timeout (default 60_000).
    * `:provider_opts` — escape hatch keyword list passed through to the
      underlying provider.
    * `:images` — list of image maps to attach to the trailing user message.
      Each entry is `%{data: binary(), media_type: String.t()}` for inline
      images or `%{url: String.t()}` for remote image URLs. Merged into the
      user message created from `prompt`, or the last user message in
      `:messages` when no prompt is given.
    * `:queue` — set to `false` to bypass the request queue for this call
      (default `true`). Has no effect when the request queue is not enabled.
    * `:queue_timeout` — milliseconds to wait for a queue slot before returning
      `{:error, :request_queue_timeout}` (default 5_000).
  """
  @spec query(String.t() | nil, keyword()) :: {:ok, Response.t()} | {:error, term()}
  def query(prompt \\ nil, opts \\ []) do
    {queue, opts} = Keyword.pop(opts, :queue, true)
    {timeout, opts} = Keyword.pop(opts, :queue_timeout, 5_000)
    provider_atom = peek_provider_atom(opts)
    {provider_mod, opts} = Config.pop_provider!(opts)
    request = Request.new(prompt, opts)

    RequestQueue.with_slot(
      provider_atom,
      fn -> provider_mod.query(request, Config.provider_opts(provider_mod, opts)) end,
      queue: queue,
      timeout: timeout
    )
  end

  @doc """
  Streaming inference. Calls `callback` with each `ExAthena.Streaming.Event` as
  tokens arrive, and returns the final `Response` when the stream completes.

  `callback` receives one argument — an `%ExAthena.Streaming.Event{}` struct —
  and its return value is ignored. Callbacks must not block the caller; if you
  need to do expensive work per-delta, hand off to a `Task`.

  Options are the same as `query/2`, including `:images`, `:queue`,
  `:queue_timeout`, and the `:provider` string form for JSON-defined providers.
  When the request queue is enabled, the slot is held for the full duration of
  the stream and released on every exit path (success, error, or callback
  exception).
  """
  @spec stream(String.t() | nil, function(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def stream(prompt \\ nil, callback, opts \\ []) when is_function(callback, 1) do
    {queue, opts} = Keyword.pop(opts, :queue, true)
    {timeout, opts} = Keyword.pop(opts, :queue_timeout, 5_000)
    provider_atom = peek_provider_atom(opts)
    {provider_mod, opts} = Config.pop_provider!(opts)
    request = Request.new(prompt, opts)

    RequestQueue.with_slot(
      provider_atom,
      fn -> provider_mod.stream(request, callback, Config.provider_opts(provider_mod, opts)) end,
      queue: queue,
      timeout: timeout
    )
  end

  @doc """
  Run a multi-turn agent loop: infer → tool call → execute → replay → repeat.

  Queueing happens **inside** the loop at per-provider-call granularity (one
  slot per inference call, released between iterations) — never one slot for
  the whole run, which would starve or deadlock concurrent loops on
  single-slot local providers. Accepts `:queue` (default `true`) and
  `:queue_timeout` (default `:infinity` — the run's own `timeout_ms` and
  budget caps bound total time).

  See `ExAthena.Loop.run/2` for the full option list.
  """
  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, opts \\ []) do
    ExAthena.Loop.run(prompt, opts)
  end

  @doc """
  Whether first-party hosts (the web UI and TUI) should confine a run to its
  working directory by default. On unless `EX_ATHENA_CONFINE` is `0`/`false`/`no`.

  Library consumers calling `run/2` directly are unaffected — they opt in with
  `confine: true` or `allowed_roots: [...]`.
  """
  @spec confine_default?() :: boolean()
  def confine_default? do
    value = "EX_ATHENA_CONFINE" |> System.get_env("1") |> String.downcase()
    value not in ["0", "false", "no"]
  end

  @doc """
  One-shot structured extraction. Returns a validated JSON map.

  Accepts `:queue` and `:queue_timeout` options (see `query/2`).

  See `ExAthena.Structured.extract/2` for the full option list.
  """
  @spec extract_structured(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract_structured(prompt, opts) do
    {queue, opts} = Keyword.pop(opts, :queue, true)
    {timeout, opts} = Keyword.pop(opts, :queue_timeout, 5_000)
    provider_atom = peek_provider_atom(opts)

    RequestQueue.with_slot(
      provider_atom,
      fn -> ExAthena.Structured.extract(prompt, opts) end,
      queue: queue,
      timeout: timeout
    )
  end

  @doc """
  Embed text. Accepts a single string or a list of strings and returns one
  vector per input, in input order.

  Batch calls are a single provider round-trip — indexing jobs embed hundreds
  of chunks per run, and one request per chunk would dominate their runtime.

      ExAthena.embed(["def foo", "def bar"], provider: :ollama)
      #=> {:ok, %ExAthena.Embedding{embeddings: [[0.1, …], [0.2, …]], …}}

  ## Options

    * `:provider` — as `query/2`. Must implement the optional `embed/2`
      callback; feature-detect with `capabilities(provider)[:embeddings]`.
    * `:model` — the embedding model. Defaults to the provider's
      `embedding_model:` config, then the top-level `:embedding_model` config.
      The provider's chat `model:` is never used — embedding models are a
      separate population (e.g. `nomic-embed-text`).
    * `:timeout_ms`, `:provider_opts`, `:queue`, `:queue_timeout` — as `query/2`.

  Configure a default embedding model alongside the chat model:

      config :ex_athena, :ollama,
        base_url: "http://localhost:11434",
        model: "qwen3-coder",
        embedding_model: "nomic-embed-text"
  """
  @spec embed(String.t() | [String.t()], keyword()) ::
          {:ok, ExAthena.Embedding.t()} | {:error, term()}
  def embed(input, opts \\ []) when is_binary(input) or is_list(input) do
    {queue, opts} = Keyword.pop(opts, :queue, true)
    {timeout, opts} = Keyword.pop(opts, :queue_timeout, 5_000)
    provider_atom = peek_provider_atom(opts)
    {provider_mod, opts} = Config.pop_provider!(opts)

    with :ok <- ensure_embeddings_supported(provider_mod),
         {:ok, model} <- resolve_embedding_model(provider_atom, opts) do
      opts = Keyword.put(opts, :model, model)

      RequestQueue.with_slot(
        provider_atom,
        fn ->
          provider_mod.embed(input, Config.provider_opts(provider_mod, opts, provider_atom))
        end,
        queue: queue,
        timeout: timeout
      )
    end
  end

  defp ensure_embeddings_supported(provider_mod) do
    if Code.ensure_loaded?(provider_mod) and function_exported?(provider_mod, :embed, 2) do
      :ok
    else
      {:error,
       ExAthena.Error.new(
         :capability,
         "#{inspect(provider_mod)} does not support embeddings",
         provider: provider_mod
       )}
    end
  end

  defp resolve_embedding_model(provider_atom, opts) do
    case Config.embedding_model(provider_atom, opts) do
      model when is_binary(model) and model != "" ->
        {:ok, model}

      _ ->
        {:error,
         ExAthena.Error.new(
           :bad_request,
           "no embedding model configured. Pass model: \"nomic-embed-text\" or set " <>
             "`config :ex_athena, :#{provider_atom}, embedding_model: \"nomic-embed-text\"`.",
           provider: provider_atom
         )}
    end
  end

  @doc """
  Returns the capabilities map for a provider.

      ExAthena.capabilities(:mock)
      #=> %{streaming: true, native_tool_calls: true, …}
  """
  @spec capabilities(atom() | module()) :: map()
  def capabilities(provider) do
    provider
    |> Config.provider_module()
    |> apply(:capabilities, [])
  end

  @doc """
  List the models a provider can serve, as `ExAthena.Model` structs.

      ExAthena.list_models(:ollama)
      #=> {:ok, [%Model{id: "qwen3-coder:30b", context_window: nil, …}]}

  Every backend answers this question in its own dialect — Ollama's
  `/api/tags`, an OpenAI-compatible `/v1/models`, or nothing at all (Anthropic
  and Google are read from the llm_db catalog). Hosts building a model picker
  get one shape regardless, and `Model.id` is exactly what to pass back as
  `model:` on the next `query/2`.

  Results are cached for five minutes in the shared model-discovery cache, so
  reopening a picker costs nothing; pass `cache: false` to force a refetch (what
  a user-facing "reload models" control should do).

  Providers that cannot enumerate their models return a `:capability` error —
  feature-detect ahead of time with `capabilities(provider)[:model_listing]` and
  fall back to a free-text model field.

  ## Options

    * `:base_url`, `:api_key` — as `query/2`; default to the provider's config.
    * `:cache` — `false` to bypass the TTL cache for this call.
    * `:include_cloud` — Ollama only: also list the `ollama.com` catalogue,
      each entry suffixed `-cloud` so it is invocable through a signed-in local
      daemon. Off by default because it reaches out to the internet.
  """
  @spec list_models(atom() | module() | nil, keyword()) ::
          {:ok, [Model.t()]} | {:error, term()}
  def list_models(provider \\ nil, opts \\ []) do
    provider_atom = provider || peek_provider_atom(opts)
    opts = Keyword.put(opts, :provider, provider_atom)

    case Config.provider_spec(provider_atom) do
      # A registry/builtin JSON spec describes its own discovery endpoint and
      # response shape; that path already exists and stays authoritative.
      {:ok, %{model_discovery: disc} = spec} when is_map(disc) ->
        with {:ok, ids} <- ModelDiscovery.list_models(spec) do
          {:ok,
           Enum.map(ids, &%Model{id: &1, name: &1, provider: provider_atom, source: :server})}
        end

      _ ->
        {provider_mod, opts} = Config.pop_provider!(opts)
        dispatch_list_models(provider_mod, provider_atom, opts)
    end
  end

  # `list_models/1` is preferred because listing depends on where the provider
  # is pointed; `list_models/0` is the older contract and only yields strings,
  # so they are lifted into structs here rather than in every such provider.
  defp dispatch_list_models(provider_mod, provider_atom, opts) do
    loaded? = Code.ensure_loaded?(provider_mod)

    cond do
      loaded? and function_exported?(provider_mod, :list_models, 1) ->
        provider_mod.list_models(Config.provider_opts(provider_mod, opts, provider_atom))

      loaded? and function_exported?(provider_mod, :list_models, 0) ->
        with {:ok, ids} <- provider_mod.list_models() do
          {:ok,
           Enum.map(
             ids,
             &%Model{id: &1, name: &1, provider: provider_atom, source: :catalog}
           )}
        end

      true ->
        {:error,
         ExAthena.Error.new(
           :capability,
           "#{inspect(provider_mod)} cannot enumerate its models",
           provider: provider_mod
         )}
    end
  end

  @doc """
  Returns `true` if the library forwards multimodal content parts
  (image / image_url / file) to the underlying provider.

  Callers can use this to decide whether to build `ExAthena.Messages.ContentPart`
  image or file parts, rather than falling back to text-only prompts.

  See `ExAthena.Messages.ContentPart`.
  """
  @spec supports_multimodal?() :: true
  def supports_multimodal?, do: true

  # ---------------------------------------------------------------------------
  # Request queue helpers
  # ---------------------------------------------------------------------------

  defp peek_provider_atom(opts) do
    Keyword.get(opts, :provider) || Application.get_env(:ex_athena, :default_provider)
  end
end
