# Providers

ExAthena ships five built-in providers plus a `:mock` for tests. Consumers
can also pass any module that implements `ExAthena.Provider` directly, or drop
a JSON file into `~/.config/ex_athena/providers/` to define a named provider
at runtime without touching `config.exs`.

## Ollama (`:ollama`)

Local Ollama via `/api/chat`. Native OpenAI-style `tool_calls` on modern
models (`llama3.1`, `qwen2.5-coder`, `mistral-nemo`, `llama3.2`, `phi-3.5`).
Streaming via newline-delimited JSON chunks.

```elixir
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "llama3.1"
```

Per-call override:

```elixir
ExAthena.query("…", provider: :ollama, model: "qwen2.5-coder")
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ (model-dependent) |
| Streaming | ✅ |
| JSON mode | ✅ via `format: "json"` |
| Resume | ❌ (use `ExAthena.Session` in Phase 2) |

## OpenAI-compatible (`:openai_compatible` / `:openai` / `:llamacpp`)

`/v1/chat/completions`. Covers every endpoint that speaks OpenAI chat
completions: OpenAI proper, OpenRouter, LM Studio, vLLM, Groq, Together AI,
DeepInfra, Fireworks, llama.cpp's server mode. Streaming via SSE.

```elixir
config :ex_athena, :openai_compatible,
  base_url: "https://api.openai.com/v1",
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o-mini"
```

### Swap endpoint per-call

```elixir
ExAthena.query("…",
  provider: :openai_compatible,
  base_url: "https://openrouter.ai/api/v1",
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4.1")
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ |
| Streaming | ✅ SSE |
| JSON mode | ✅ via `response_format: %{type: "json_object"}` |
| Resume | ❌ |

## Claude (`:claude`)

Wraps the `claude_code` SDK. Preserves every feature the SDK provides
natively — hooks, `can_use_tool` callbacks, MCP servers, session resume,
prompt cache reuse — by passing them through via `:provider_opts`.

```elixir
config :ex_athena, :claude,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-opus-4-8"
```

The `claude_code` dep is declared `optional: true` on `ex_athena`; if you
use this provider, add it to your own deps:

```elixir
{:claude_code, "~> 0.36"}
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ `tool_use` blocks |
| Streaming | Phase 2 (via `ExAthena.Session`) |
| JSON mode | ❌ (use structured output in Phase 2) |
| Resume | ✅ via the SDK's session resume |

## Gemini (`:gemini`)

Google Gemini via the Google AI Studio API. Backed by `req_llm`'s Google
adapter — supports native tool calls (via v1beta, the default) and streaming
via SSE.

```elixir
config :ex_athena, :gemini,
  api_key: System.get_env("GOOGLE_API_KEY"),
  model: "gemini-2.5-flash"
```

Per-call override:

```elixir
ExAthena.query("…", provider: :gemini, model: "gemini-2.5-pro")
```

For the full walkthrough — API key setup, model table, tool-calling caveats,
and rate-limit notes — see the **[Gemini setup guide](gemini.md)**.

## OpenRouter (`:openrouter`)

Hosted model gateway that routes to hundreds of models from Anthropic, Google,
Meta, Mistral, and others through a single OpenAI-compatible endpoint. Requires
an [OpenRouter API key](https://openrouter.ai).

```elixir
config :ex_athena, :openrouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4-8"
```

Per-call model switch:

```elixir
ExAthena.query("…", provider: :openrouter, model: "google/gemini-2.5-pro")
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ (model-dependent) |
| Streaming | ✅ SSE |
| JSON mode | ✅ via `response_format: %{type: "json_object"}` |
| Resume | ❌ |

## Mock (`:mock`)

Unit-test double. Scripted responses either via canned text or a responder
function, plus optional per-call event lists for streaming tests.

```elixir
ExAthena.query("ping", provider: :mock, mock: [text: "pong"])

# Dynamic:
responder = fn request -> %ExAthena.Response{text: "echo: " <> hd(request.messages).content} end
ExAthena.query("hi", provider: :mock, mock: [responder: responder])

# Streaming:
events = [
  %ExAthena.Streaming.Event{type: :text_delta, data: "Hello"},
  %ExAthena.Streaming.Event{type: :text_delta, data: " world"},
  %ExAthena.Streaming.Event{type: :stop, data: :stop}
]
ExAthena.stream("hi", fn _ -> :ok end,
  provider: :mock,
  mock: [text: "Hello world"],
  mock_events: events)
```

## Vision / multimodal

Vision support varies by provider. Pass `images: [%{data: binary(), media_type: String.t()}]`
(or `%{url: String.t()}` entries) to any `ExAthena.query/2`, `ExAthena.stream/3`, or
`ExAthena.run/2` call. See the **[Multimodal guide](multimodal.md)** for the full
walkthrough including examples for each provider.

| Provider | Vision support | Notes |
|---|---|---|
| `:ollama` | Model-dependent | `llava`, `qwen2-vl`, `llava-phi3`, `bakllava` |
| `:openai_compatible` | ✅ gpt-4o, gpt-4o-mini | URL + inline |
| `:claude` | ✅ Any `claude-3`+ model | PNG, JPEG, GIF, WebP |
| `:gemini` | ✅ Any `gemini-1.5`+ model | Inline + URL |

## Embeddings

Every provider that routes through the ReqLLM adapter (`:ollama`, `:openai`,
`:gemini`, `:openrouter`, JSON-file providers, …) can also embed, plus `:mock`
for tests. Because embedding models are a separate population from chat models,
they live under their own key and are never inferred from `model:`:

```elixir
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "qwen3-coder",
  embedding_model: "nomic-embed-text"
```

```elixir
{:ok, %ExAthena.Embedding{embeddings: vectors}} =
  ExAthena.embed(["chunk one", "chunk two"], provider: :ollama)
```

Feature-detect with `ExAthena.capabilities(provider)[:embeddings]`. See the
**[Embeddings guide](embeddings.md)**.

## Listing models

`ExAthena.list_models/2` answers "what can this provider run?" for every
provider through one call, so a host building a model picker never has to learn
a backend's wire format:

```elixir
{:ok, models} = ExAthena.list_models(:ollama)

Enum.map(models, & &1.id)
#=> ["llama3.1:latest", "qwen3-coder:30b"]
```

Each entry is an `ExAthena.Model` — `:id` (pass it straight back as `model:` on
the next call), `:name`, `:provider`, `:context_window`, `:max_output_tokens`
and `:source`.

Where the answer comes from depends on the backend, which is exactly the detail
this API exists to hide:

| Provider | Source |
|---|---|
| `:ollama` | the daemon's `GET /api/tags` |
| `:llamacpp`, `:exo` | the server's `GET /v1/models` |
| `:openai`, `:openrouter`, JSON-file providers | the endpoint's `GET /v1/models` |
| `:anthropic`, `:gemini` | the llm_db catalog — they publish no list endpoint |
| `:claude_code` | the models the CLI reports |

`:context_window` is `nil` when it cannot be established honestly. Local servers
do not report it and most local models are absent from the catalog; a guessed
value would silently mis-size compaction, so absence is reported instead.

Results are cached for five minutes (in the same TTL cache that already served
JSON-file providers), so reopening a picker is free. A user-facing "reload
models" control should pass `cache: false`:

```elixir
ExAthena.list_models(:ollama, cache: false)
```

Ollama can additionally list the [ollama.com](https://ollama.com) catalog, each
name suffixed `-cloud` so it is invocable through a signed-in local daemon
(`ollama signin`). It is off by default because it reaches out to the internet,
and it fails soft — an offline machine still shows the locally installed models:

```elixir
ExAthena.list_models(:ollama, include_cloud: true)
```

Feature-detect with `ExAthena.capabilities(provider)[:model_listing]` and fall
back to a free-text model field when it is absent.

> The old per-backend helpers — `ExAthena.Chat.Ollama.list_models/1`,
> `list_cloud_models/1`, `ExAthena.Chat.LlamaCpp.list_models/1` and
> `ExAthena.Chat.Exo.list_models/1` — are deprecated shims over this API and
> still return their original strings and error atoms.

## Runtime JSON config

ExAthena reads every `*.json` file from `~/.config/ex_athena/providers/` at
application startup via `ExAthena.ProviderRegistry`. Each file defines one named
provider that you reference by its `name` string, the same way you pass a
built-in atom.

```elixir
ExAthena.query("…", provider: "my-groq")
ExAthena.query("…", provider: "my-groq", model: "mixtral-8x7b-32768")
```

Files that fail validation are skipped with a warning — a single bad file does
not prevent others from loading and the application still starts.

### Schema

| Field | Type | Required | Default | Notes |
|---|---|---|---|---|
| `name` | string | ✅ | — | Unique provider name; used as the lookup key |
| `adapter` | string | ✅ | — | `"req_llm"` or `"mock"` |
| `req_llm_provider_tag` | string | — | `null` | req_llm routing tag (`"openai"`, `"anthropic"`, `"google"`) |
| `base_url` | string | — | `null` | Override the adapter's default endpoint URL |
| `api_key` | string | — | `null` | Static API key (prefer `api_key_env` — see Security) |
| `api_key_env` | string | — | `null` | Environment variable name; key is read at startup |
| `default_model` | string | — | `null` | Model used when no `model:` is supplied per-call |
| `api_key_prompt` | boolean | — | `false` | When `true`, the web UI sidebar shows an inline API-key password field; key is held in socket state and never written to disk. Web UI only — has no effect in the TUI. |
| `metadata` | object | — | `{}` | Arbitrary pass-through data; ignored by ExAthena |

### Security

Never store raw API keys in JSON files that may be committed to version control.

* Use `api_key_env` to name the environment variable instead of embedding the
  key directly:

```json
{
  "name": "my-groq",
  "adapter": "req_llm",
  "req_llm_provider_tag": "openai",
  "base_url": "https://api.groq.com/openai/v1",
  "api_key_env": "GROQ_API_KEY",
  "default_model": "llama-3.3-70b-versatile"
}
```

* Restrict file permissions on any file that does contain a literal key:

```sh
chmod 600 ~/.config/ex_athena/providers/my-provider.json
```

* Add `~/.config/ex_athena/providers/` to `.gitignore` when files may contain
  credentials.

### Writing your own

1. **`name`** must be a non-empty string unique across all files in the
   directory. It becomes the string you pass to `provider:`.
2. **`adapter`** must be exactly `"req_llm"` (any HTTP-based model endpoint) or
   `"mock"` (tests only).
3. **`req_llm_provider_tag`** routes requests through req_llm's model catalog.
   Use `"openai"` for OpenAI-compatible endpoints, `"anthropic"` for Anthropic,
   `"google"` for Google Gemini.
4. **Validation errors** (missing required fields, unknown adapter, malformed
   JSON) are logged as warnings and the file is skipped — the application still
   starts normally.
5. Files are loaded once at startup. Restart the application to pick up changes.

Ready-to-copy examples live in `priv/provider_examples/`.

## Groq

[Groq](https://groq.com) provides ultra-fast inference for open-source models on
dedicated LPU hardware.

```json
{
  "name": "groq",
  "adapter": "req_llm",
  "req_llm_provider_tag": "openai",
  "base_url": "https://api.groq.com/openai/v1",
  "api_key_env": "GROQ_API_KEY",
  "default_model": "llama-3.3-70b-versatile"
}
```

Copy `priv/provider_examples/groq.json` to `~/.config/ex_athena/providers/` and
set `GROQ_API_KEY`. Supported models include `llama-3.3-70b-versatile`,
`llama-3.1-8b-instant`, and `mixtral-8x7b-32768`.

## Together AI

[Together AI](https://www.together.ai) hosts a broad catalog of open-source
models with optional fine-tuning.

```json
{
  "name": "together",
  "adapter": "req_llm",
  "req_llm_provider_tag": "openai",
  "base_url": "https://api.together.xyz/v1",
  "api_key_env": "TOGETHER_API_KEY",
  "default_model": "meta-llama/Llama-3-70b-chat-hf"
}
```

Copy `priv/provider_examples/together.json` to `~/.config/ex_athena/providers/`
and set `TOGETHER_API_KEY`.

## Fireworks AI

[Fireworks AI](https://fireworks.ai) offers serverless inference for popular
open-source models with low latency.

```json
{
  "name": "fireworks",
  "adapter": "req_llm",
  "req_llm_provider_tag": "openai",
  "base_url": "https://api.fireworks.ai/inference/v1",
  "api_key_env": "FIREWORKS_API_KEY",
  "default_model": "accounts/fireworks/models/llama-v3p3-70b-instruct"
}
```

Copy `priv/provider_examples/fireworks.json` to
`~/.config/ex_athena/providers/` and set `FIREWORKS_API_KEY`.

## DeepSeek

[DeepSeek](https://www.deepseek.com) provides cost-effective inference for the
DeepSeek family of models.

```json
{
  "name": "deepseek",
  "adapter": "req_llm",
  "req_llm_provider_tag": "openai",
  "base_url": "https://api.deepseek.com/v1",
  "api_key_env": "DEEPSEEK_API_KEY",
  "default_model": "deepseek-chat"
}
```

Copy `priv/provider_examples/deepseek.json` to
`~/.config/ex_athena/providers/` and set `DEEPSEEK_API_KEY`. Use
`"deepseek-reasoner"` for the reasoning-optimised variant.

## Custom providers

Implement the `ExAthena.Provider` behaviour:

```elixir
defmodule MyApp.MyProvider do
  @behaviour ExAthena.Provider

  @impl true
  def capabilities, do: %{native_tool_calls: false, streaming: false}

  @impl true
  def query(%ExAthena.Request{} = req, _opts) do
    # … make your call, return {:ok, %ExAthena.Response{}}
  end
end

ExAthena.query("hi", provider: MyApp.MyProvider)
```

Capabilities are used by the agent loop (Phase 2) to pick the right
tool-call protocol. Declare what you actually support — if you lie, the
loop will fall back automatically.
