# Terminal chat (mix athena.chat)

`mix athena.chat` drops you into a full-screen TUI powered by
[ExRatatui](https://github.com/mcass19/ex_ratatui). It connects to
the ExAthena agent loop, streams tokens live, and surfaces tool calls and
their results inline.

## Prerequisites

The TUI requires the optional `:ex_ratatui` dependency:

```elixir
# mix.exs
{:ex_ratatui, "~> 0.11"}
```

ExAthena declares it `optional: true` so projects that only use the
programmatic API don't pull it in. Without it, `mix athena.chat` prints
an error and exits.

## Launching

```bash
mix athena.chat
mix athena.chat --provider llamacpp
mix athena.chat --provider ollama --model qwen2.5-coder:14b
mix athena.chat --mode plan_and_solve
mix athena.chat -p ~/projects/my_app
```

### Flags

| Flag | Alias | Description |
|---|---|---|
| `--provider NAME` | | Which provider to use (`:ollama`, `:llamacpp`, `:openai_compatible`, `:claude`, `:gemini`, `:openrouter`, or a JSON-defined name). Defaults to `config :ex_athena, default_provider:`. |
| `--model NAME` | | Initial model. Overrides the provider's configured default. |
| `--mode NAME` | | Agent mode: `react`, `plan_and_solve`, or `reflexion`. |
| `--path PATH` | `-p` | Working directory for filesystem tools. `~` is expanded. The chat process does **not** `cd` — tools just receive this as their `cwd`. |

## Selecting a provider

### Built-in providers

Providers are configured in `config/config.exs`. The TUI reads the same
configuration your application uses at runtime:

```elixir
# Ollama (local, free — requires `ollama serve`)
config :ex_athena, default_provider: :ollama
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "qwen2.5-coder:14b"

# llama.cpp (local, free — requires `llama-server --model ...`)
config :ex_athena, :llamacpp,
  base_url: "http://localhost:8080",
  model: "qwen2.5-coder"

# OpenAI / OpenAI-compatible
config :ex_athena, :openai_compatible,
  base_url: "https://api.openai.com/v1",
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o-mini"

# Anthropic Claude
config :ex_athena, :claude,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-opus-4-8"

# Google Gemini
config :ex_athena, :gemini,
  api_key: System.get_env("GOOGLE_API_KEY"),
  model: "gemini-2.5-flash"

# OpenRouter
config :ex_athena, :openrouter,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4-8"
```

Then launch with the provider you configured:

```bash
mix athena.chat --provider openai_compatible
mix athena.chat --provider gemini --model gemini-2.5-pro
```

### JSON-defined providers

ExAthena loads every `*.json` file in `~/.config/ex_athena/providers/` at
startup. Drop a file there to define a named provider without touching
`config.exs` — useful for personal keys that shouldn't live in a project
repository:

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

```bash
mix athena.chat --provider groq
```

The `api_key_env` field names the environment variable that holds the key.
The key is read once at application startup and held in memory for the
session — it is never written to disk by the TUI. Use `api_key_env`
instead of a literal `api_key` field for any file that may be shared.

The `api_key_prompt: true` field has no effect in the TUI — it only
activates the inline key field in the web sidebar (`mix athena.web`).
See the [Web UI guide](web.md#inline-api-key-prompt) for details.

See the [providers guide](providers.md) for the full JSON schema and
ready-to-copy examples for Groq, Together AI, Fireworks, DeepSeek, and
others.

## Layout

```
┌─────────────────────────────────────────────────────┬────────────────────┐
│ ollama · qwen2.5-coder:14b · react  iter 3  1.2k t  │ Timeline  Changes  │
├─────────────────────────────────────────────────────┤                    │
│                                                     │ iteration 1        │
│  You: refactor the auth module                      │ → read             │
│                                                     │   {"path":"lib/…"} │
│  Assistant: I'll start by reading the current …     │ ← result           │
│                                                     │   defmodule Auth…  │
│  ● read(lib/auth.ex)                                │ iteration 2        │
│    └ defmodule Auth do                              │ → edit             │
│                                                     │   …                │
│  ● edit(lib/auth.ex)                                │                    │
│    └ patch applied (14 lines)                       │                    │
│                                                     │                    │
├─────────────────────────────────────────────────────┤                    │
│ ┌─────────────────────────────────────────────────┐ │                    │
│ │ /                                               │ │                    │
│ └─────────────────────────────────────────────────┘ │                    │
├─────────────────────────────────────────────────────┴────────────────────┤
│ Enter: send  Ctrl+C: quit  /help                                          │
└───────────────────────────────────────────────────────────────────────────┘
```

- **Header** — active provider, model, mode, iteration count, token usage, and accumulated cost.
- **Messages** (left, flex height) — streaming assistant text, tool-call blocks with inline output previews.
- **Details** (right pane) — Timeline tab shows the full tool argument / result for every call; Changes tab shows `git diff HEAD` refreshed after each tool result.
- **Input** — multiline textarea. `Enter` sends; `Shift+Enter` inserts a newline.
- **Footer** — context-sensitive keyboard hints.

## Model and mode pickers

Typing `/model` or `/mode` with no argument opens a scrollable popup over
the messages area:

```
┌──────────────────────────────┐
│ Select model                 │
│ ▶ qwen2.5-coder:14b          │
│   llama3.1                   │
│   mistral-nemo               │
│   phi-3.5                    │
└──────────────────────────────┘
```

- `↑` / `k` — move up
- `↓` / `j` — move down
- `Enter` — confirm selection
- `Esc` — close without selecting

Or set directly to skip the picker:

```
/model mistral-nemo
/mode plan_and_solve
```

## Slash commands

Type `/` in the input to open autocomplete. A dropdown shows matching
commands and their descriptions as you type the verb. Press `Tab` or
`Enter` on a suggestion to complete it.

| Command | Description |
|---|---|
| `/help`, `/?` | Show full usage help |
| `/clear` | Wipe the conversation history and start a fresh session |
| `/tools` | List the tools currently available to the agent |
| `/model [name]` | Open the model picker, or set the model directly |
| `/mode [name]` | Open the mode picker, or set the mode directly (`react`, `plan_and_solve`, `reflexion`) |
| `/expand [N]` | Show the full text of the Nth most-recent tool result (default: 1 = most recent) |
| `/details [on\|off]` | Show or hide the right details pane; no argument toggles |
| `/tab` | Cycle the details pane tab: Timeline ↔ Changes |
| `/timeline` | Switch to the Timeline tab |
| `/diff [side\|inline]` | Switch to the Changes tab; optionally set the layout (`side` = side-by-side, `inline` = unified diff) |
| `/cd PATH` | Set the working directory for filesystem tools (`~` is expanded; the chat process does not chdir) |
| `/pwd` | Print the current working directory |
| `/mouse [on\|off]` | Toggle crossterm mouse capture; `off` restores native terminal text selection |
| `/exit`, `/quit`, `/q` | Leave the chat |

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Enter` | Send message |
| `Shift+Enter` | Insert newline |
| `Ctrl+C` | Quit |
| `↑` / `↓` | Navigate input history (outside a picker) |
| `↑` / `k`, `↓` / `j` | Move picker / autocomplete selection |
| `Esc` | Close picker without selecting |
| `PgUp` / `PgDn` | Scroll the messages pane by ~10 rows |
| `Shift+PgUp` / `Shift+PgDn` | Scroll the details pane |
| `End` | Jump both panes back to the bottom (auto-follow mode) |
| Mouse wheel | Scroll the pane under the cursor (requires mouse capture on) |

Mouse capture is on by default. Use `/mouse off` to drop back to native
terminal copy/paste (click-drag to select). Many terminals also let you
bypass capture temporarily by holding `Option` (macOS) or `Shift` while
click-dragging.

## Streaming and thinking

Tokens stream directly into the messages pane as they arrive. Models that
emit `<think>` or `<thinking>` blocks have those routed to the details
pane in real time — you see the reasoning on the right while the final
answer builds on the left.

## Tool output

Each tool call renders as a collapsible block in the messages pane:

```
● read(lib/auth.ex)
  └ defmodule Auth do
      @moduledoc "…
      …4 more lines (18 total)
```

The preview shows up to four lines. To see the full output, use `/expand`
(or `/expand 2` for the second-most-recent result). The details pane
always shows the complete text.

## Tips

- **Working directory**: set `-p ~/projects/my_app` at launch or use `/cd`
  during the session. The TUI shows the active path in the details pane
  header after `/cd`.
- **Long responses**: if the model is still running and you need to scroll
  up to re-read earlier output, `PgUp` pauses auto-follow. `End` or
  sending your next message resumes it.
- **Side-by-side diff**: `/diff side` switches the Changes tab to a
  two-column layout. `/diff inline` or `/diff` switches back to unified.
- **Mode switching**: `plan_and_solve` adds an explicit planning phase
  before the agent executes tools — useful for complex multi-file tasks.
  `reflexion` adds a self-critique loop after each iteration.
