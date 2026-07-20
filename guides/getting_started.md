# Getting started

This guide takes you from zero to a running ExAthena call in under five minutes.

## Install

```bash
mix igniter.install ex_athena
```

The installer:

- Adds `{:ex_athena, "~> 0.12"}` to your deps.
- Writes `config :ex_athena, default_provider: :ollama` (and per-provider defaults) to `config/config.exs`.
- Is idempotent — re-running preserves whatever you've already configured.

Alternatively, add the dep manually:

```elixir
def deps do
  [
    {:ex_athena, "~> 0.12"},
    {:claude_code, "~> 0.36"}  # only needed for the :claude provider
  ]
end
```

…then run `mix ex_athena.install` once to wire up defaults.

## Pick a provider

### Ollama (local, free)

```bash
ollama pull llama3.1
ollama serve
```

```elixir
config :ex_athena, default_provider: :ollama
config :ex_athena, :ollama, base_url: "http://localhost:11434", model: "llama3.1"
```

### OpenAI / OpenAI-compatible

```elixir
config :ex_athena, default_provider: :openai_compatible
config :ex_athena, :openai_compatible,
  base_url: "https://api.openai.com/v1",
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o-mini"
```

Swap `base_url` for any OpenAI-compatible endpoint (OpenRouter, LM Studio, Groq, Together, vLLM, llama.cpp in server mode).

### Anthropic Claude

```elixir
config :ex_athena, default_provider: :claude
config :ex_athena, :claude,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-opus-4-8"
```

## Make a call

```elixir
{:ok, response} = ExAthena.query("What is 2+2?")
IO.puts(response.text)
```

`response` is an `%ExAthena.Response{}` with:

- `:text` — concatenated assistant text
- `:tool_calls` — any tool calls the model wants the runtime to execute
  (always empty for `query/2` unless you passed `:tools`; `ExAthena.run/2`
  executes them for you)
- `:finish_reason` — `:stop | :length | :tool_calls | :content_filter | :error`
- `:usage` — token accounting when the provider reports it
- `:model`, `:provider`, `:raw`

## Stream the response

```elixir
ExAthena.stream("Explain quantum computing in plain English", fn event ->
  case event.type do
    :text_delta -> IO.write(event.data)
    :stop -> IO.puts("\n[done]")
    _ -> :ok
  end
end)
```

The callback runs on every delta — keep it fast. If you need to do expensive
work per-delta, hand off to a `Task`.

## Next steps

- [Providers](providers.md) — full config surface for each provider.
- [Tool calls](tool_calls.md) — native vs text-tagged protocols.
- [The agent loop](agent_loop.md) — `ExAthena.run/2`, `ExAthena.Tool`,
  `ExAthena.Session`, and `ExAthena.extract_structured/2`.
- [Embeddings](embeddings.md) — `ExAthena.embed/2`.
