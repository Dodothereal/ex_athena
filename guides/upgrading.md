# Upgrading ExAthena

This guide covers migration steps for notable version changes.

## Upgrading to runtime provider config (current)

ExAthena now loads provider definitions from JSON files at startup in addition
to the traditional `config.exs` approach. **No migration is required** — every
existing `config :ex_athena, :provider_atom, [...]` entry continues to work
exactly as before.

### What's new

A `ProviderRegistry` reads every `*.json` file from
`~/.config/ex_athena/providers/` at application boot. Each file defines one
named provider that you pass to `provider:` as a string:

```elixir
ExAthena.query("…", provider: "my-groq")
ExAthena.query("…", provider: "my-groq", model: "mixtral-8x7b-32768")
```

Files that fail validation are skipped with a warning — a bad file does not
prevent the application from starting or other providers from loading.

### Existing config.exs setup — no changes needed

If you already configure providers in `config.exs`, keep doing so:

```elixir
# config/config.exs — still works, nothing to change
config :ex_athena, default_provider: :ollama
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "llama3.1"

config :ex_athena, :openrouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4-5"
```

Per-call opts still override everything:

```elixir
ExAthena.query("…", provider: :ollama, model: "qwen2.5-coder:14b")
```

### Adding a new provider via JSON (OpenRouter, Groq, Together, etc.)

If you want to use a hosted provider like OpenRouter without touching
`config.exs`, drop a JSON file into `~/.config/ex_athena/providers/`:

**Step 1 — copy an example:**

```bash
mkdir -p ~/.config/ex_athena/providers/
cp deps/ex_athena/priv/provider_examples/openrouter.json \
   ~/.config/ex_athena/providers/openrouter.json
```

Ready-to-use examples ship in `priv/provider_examples/`:

- `openrouter.json` — routes to hundreds of models through a single endpoint
- `groq.json` — ultra-low-latency Llama and Mixtral inference
- `together.json` — broad catalog of hosted open-source models
- `fireworks.json` — fast serverless inference
- `deepseek.json` — cost-effective DeepSeek-series models

**Step 2 — set the API key env var:**

Each example file uses `api_key_env` to name the environment variable to read:

```bash
export OPENROUTER_API_KEY="sk-or-…"
```

**Step 3 — use the provider:**

```elixir
ExAthena.query("…", provider: "openrouter")
ExAthena.query("…", provider: "openrouter", model: "google/gemini-2.5-pro")
```

Or set it as the default in `config.exs`:

```elixir
config :ex_athena, default_provider: "openrouter"
```

### Picking a provider in the TUI and web UI

Both `mix athena.chat` and `mix athena.web` surface every registered provider —
both built-in atoms and JSON-defined names — in their provider picker. No extra
configuration is needed once the JSON file is in place.

### Full schema reference

See the **[Providers guide](providers.md#runtime-json-config)** for the
complete field reference, security recommendations, and instructions for writing
a custom JSON provider.
