# ExAthena

[![Hex.pm](https://img.shields.io/hexpm/v/ex_athena.svg)](https://hex.pm/packages/ex_athena)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_athena)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)

Provider-agnostic agent loop for Elixir. Drop-in replacement for the Claude
Code SDK that runs on **Ollama**, **OpenAI-compatible endpoints**
(OpenAI, OpenRouter, LM Studio, vLLM, Groq, Together, llama.cpp server…),
**Google Gemini**, or **Anthropic Claude** itself — with the same tools,
hooks, permissions, and streaming semantics across every provider.

> **Status (v0.12):** two front-ends land on top of the agent loop — a
> full-screen terminal TUI (`mix athena.chat`, built on `ex_ratatui`) with
> split message/details panes, real-time thinking, a live `git diff` Changes
> tab, mouse support, and a stop button; and a Phoenix LiveView web UI
> (`mix athena.web`) with session recall, fork, and a diff viewer. This
> release also adds a first-class **llama.cpp** provider and streams
> thinking/reasoning deltas as loop events. The TUI/web deps (`ex_ratatui`,
> `phoenix`, `phoenix_live_view`, `bandit`) are now **optional**, so the core
> library stays lean. See the [v0.12.0 changelog](CHANGELOG.md#v0120--interactive-tui-web-ui-llamacpp-provider-thinking-prompt-hardening)
> for the full list.
>
> The operational harness it builds on — file-based memory
> (`AGENTS.md`/`CLAUDE.md`), Claude Code-style skills, a five-stage compaction
> pipeline, 14 hook events, five permission modes, custom agents with
> git-worktree isolation, and append-only session storage with checkpointing —
> is documented under [The operational harness](#the-operational-harness-v04).

## Why

If you're using `claude_code` today and want to switch to a local Ollama
model — or route per-task to OpenAI-compatible endpoints, or try Groq
behind the same Elixir code — you don't want to rewrite every orchestrator.
ExAthena is that abstraction layer. Pick a provider, run the same call,
get back the same shape.

## Install

The one-liner (Igniter auto-installs + writes sensible config):

```bash
mix igniter.install ex_athena
```

Or manually — add to `mix.exs`:

```elixir
def deps do
  [
    {:ex_athena, "~> 0.12"},
    # optional — only needed for the Claude provider:
    {:claude_code, "~> 0.36"},
    # optional — only needed for the TUI (`mix athena.chat`):
    {:ex_ratatui, "~> 0.10"},
    # optional — only needed for the web UI (`mix athena.web`):
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:bandit, "~> 1.5"}
  ]
end
```

The core agent loop has no Phoenix/TUI dependency; add the optional deps above
only if you want `mix athena.chat` or `mix athena.web`. Then run
`mix ex_athena.install` once to wire up defaults, or configure manually (see
[Configuration](#configuration)).

## Configuring providers

Provider settings resolve in three layers, highest priority first:

1. **Per-call opts** — `ExAthena.query("…", provider: :groq, model: "…")` — overrides everything.
2. **Application config** — `config :ex_athena, :ollama, model: "…"` in `config.exs`.
3. **JSON files** — `~/.config/ex_athena/providers/*.json` — named providers loaded at startup.

**Quickstart with a JSON provider (Groq):**

```bash
mkdir -p ~/.config/ex_athena/providers
cp priv/provider_examples/groq.json ~/.config/ex_athena/providers/
export GROQ_API_KEY=gsk_…
mix athena.chat
```

ExAthena reads `groq.json` at startup and makes `"groq"` available by name. Full schema,
security notes, and example files for Groq, Together, Fireworks, DeepSeek, and OpenRouter are
in [guides/providers.md](guides/providers.md).

## Quick start

```elixir
# config/config.exs
config :ex_athena, default_provider: :ollama
config :ex_athena, :ollama, base_url: "http://localhost:11434", model: "llama3.1"

# anywhere
{:ok, response} = ExAthena.query("Tell me a joke")
IO.puts(response.text)

# streaming
ExAthena.stream("Explain quantum computing", fn event ->
  case event.type do
    :text_delta -> IO.write(event.data)
    :stop -> IO.puts("\n[done]")
    _ -> :ok
  end
end)
```

Swap the provider by changing one option:

```elixir
ExAthena.query("hi", provider: :openai_compatible, model: "gpt-4o-mini")
ExAthena.query("hi", provider: :claude, model: "claude-opus-4-5")
ExAthena.query("hi", provider: :ollama, model: "qwen2.5-coder")
ExAthena.query("hi", provider: :gemini, model: "gemini-2.5-flash")
```

Attach images with the `images:` shorthand — same API across every provider:

```elixir
png = File.read!("diagram.png")
{:ok, response} = ExAthena.query("Describe this diagram",
  provider: :ollama,
  model: "llava",
  images: [%{data: png, media_type: "image/png"}]
)
```

See the [Multimodal guide](guides/multimodal.md) for inline images, URL
references, and per-provider notes.

## Try it: `mix athena.chat`

Drop into an interactive chat REPL against a local Ollama model:

```bash
ollama serve &              # if not already running
ollama pull llama3.1        # any model you like

mix athena.chat
mix athena.chat --model qwen2.5-coder:14b --mode plan_and_solve
```

Tokens stream in real time. A pinned status line at the bottom tracks the
current model, runner mode, iteration count, token usage, and cost. Slash
commands switch state without restarting:

| Command | What it does |
|---|---|
| `/model` | Live-list installed Ollama models and pick one |
| `/mode` | Switch between `react`, `plan_and_solve`, `reflexion` |
| `/tools` | Show the tools the agent currently has access to |
| `/clear` | Wipe conversation history (start a fresh thread) |
| `/help` | Print the command reference |
| `/exit` (or Ctrl-D) | Leave |

Defaults: `:ollama` provider, the model in `config :ex_athena, :ollama, :model`,
`:react` runner, every builtin tool, `permission_mode: :default`.

## Try it: `mix athena.web`

A browser-based chat UI with the same agent loop, accessible from any device on your network:

```bash
mix athena.web                  # http://0.0.0.0:4000
mix athena.web --port 8080      # custom port
```

The sidebar lets you switch provider, model, and mode without restarting. Features:

| Feature | Description |
|---|---|
| **Session recall** | Every completed turn is auto-saved to `~/.ex_athena/web/sessions/`. Click "▼ Sessions" in the sidebar to load or delete past conversations. |
| **Fork** | Each assistant message has a `⑂ fork` button. It snapshots the conversation history at that point and opens a new branch — the original session is untouched. |
| **Diff viewer** | File edits show a "▼ view" button next to the tool result. Click it for a color-coded line diff (`+` green / `−` red) computed server-side. Bash tool calls show exit code, runtime, and stdout. File reads show the content. |
| **Action indicator** | While the model is running, a `⚡ Reading · foo.ex` pill in the message header tracks the current tool call in real time. |
| **Markdown** | Completed responses are rendered with headings, fenced code blocks (with language label), inline code, bold/italic, lists, links, and horizontal rules — no CDN or build step required. |

The web UI is a Phoenix LiveView application that requires no separate server process — `mix athena.web` starts everything in one command. Sessions are serialized with `:erlang.term_to_binary` and survive restarts. The JS bundle is served directly from the installed `phoenix` and `phoenix_live_view` hex packages, so there is no npm or esbuild step.

> **Note:** `phoenix`, `phoenix_live_view`, and `bandit` are optional dependencies. Add them to your `mix.exs` (see [Install](#install)) before running `mix athena.web`.

## Providers

| Provider | Module | Notes |
|---|---|---|
| `:ollama` | `ExAthena.Providers.ReqLLM` | Local Ollama, `/api/chat`. Native tool-calls on modern models. |
| `:openai_compatible` | `ExAthena.Providers.ReqLLM` | `/v1/chat/completions` — covers OpenAI, OpenRouter, LM Studio, vLLM, Groq, Together, llama.cpp server mode, etc. |
| `:openai` | `ExAthena.Providers.ReqLLM` | Alias for `:openai_compatible`. |
| `:llamacpp` | `ExAthena.Providers.ReqLLM` | Alias for local llama.cpp server. |
| `:claude` | `ExAthena.Providers.ReqLLM` | Anthropic Claude via req_llm. |
| `:gemini` | `ExAthena.Providers.ReqLLM` | Google Gemini via AI Studio (routed through `req_llm`'s Google adapter). Native tool calls + streaming. See [setup guide](guides/gemini.md). |
| `:mock` | `ExAthena.Providers.Mock` | In-memory test double. |

Pass a custom module that implements `ExAthena.Provider` directly if you
have an endpoint that doesn't fit the above.

## Configuration

```elixir
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
  model: "claude-opus-4-5"
```

Resolution is **tiered** — per-call opts always beat app env:

```elixir
ExAthena.query("…",
  provider: :openai_compatible,          # overrides default_provider
  base_url: "https://openrouter.ai/api/v1",  # overrides :openai_compatible, base_url
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4.1")
```

## Tool calls

`ExAthena.ToolCalls` handles both protocols and auto-falls-back between them:

- **Native** — OpenAI `tool_calls` arrays and Anthropic `tool_use` blocks.
  Parsed into canonical `ExAthena.Messages.ToolCall` structs.
- **TextTagged** — `~~~tool_call {json}` fenced blocks embedded in assistant
  prose, for models without native support.

The agent loop (Phase 2) will pick the protocol based on the provider's
declared capabilities, and fall back when the model gets it wrong.

## The operational harness (v0.4)

The "1.6% reasoning, 98.4% harness" upgrade — built around the
[Claude Code paper](https://arxiv.org/abs/2604.14228)'s observation
that production agent value comes from the operational scaffolding,
not the loop itself.

**File-based context.** Drop an `AGENTS.md` (or `CLAUDE.md`) at the
project root and ex_athena prepends it as user-context on every turn.
Drop a `SKILL.md` with YAML frontmatter under `.exathena/skills/<name>/`
and its description joins the system-prompt catalog at ~50 tokens; the
body loads only when the model writes `[skill: <name>]`. See the
[memory + skills guide](guides/memory_and_skills.md).

**Five-stage compaction.** The default
[Compactor.Pipeline](guides/compaction_pipeline.md) runs cheapest-first:
budget reduction (truncate huge tool results) → snip (drop stale
ones) → microcompact (collapse runs of identical calls) → context
collapse (read-time-only projection) → LLM summary. When a provider
returns "context too long" the pipeline forces every stage and
retries.

**14-event hook surface.** Every transition in the loop is
observable + interceptable: `SessionStart/End`, `UserPromptSubmit`,
`ChatParams`, `Stop`, `StopFailure`, all the `*ToolUse*` variants,
`PermissionRequest/Denied`, `Subagent*`, three compaction events,
`Notification`. Hooks can `{:inject, msg}` to add context or
`{:transform, prompt}` to rewrite the user's message. See
[hooks reference](guides/hooks_reference.md).

**Five permission modes.** Add `:accept_edits` (auto-allow file
edits, still prompt for `bash`) and `:trusted` (skip prompts; with
optional `respect_denylist: false` for full YOLO) on top of the
existing `:plan` / `:default` / `:bypass_permissions`. The denylist
always wins, including in bypass — that's locked in a doctest. See
[permissions](guides/permissions.md).

**Subagents v2.** Define custom agents in `.exathena/agents/<name>.md`
with frontmatter (`tools`, `permissions`, `mode`, `isolation`); spawn
by name via `agent: "explore"`. Optional git-worktree isolation
creates an isolated checkout per subagent (with safety checks +
graceful fallback). Sidechain transcripts persist the full subagent
conversation to disk so the parent only spends tokens on the final
text. Three builtin definitions ship: `general`, `explore`, `plan`.
See [agents + subagents](guides/agents_subagents.md).

**Storage + checkpoint.** `ExAthena.Sessions.Store` is an
append-only event log behaviour with two stores: in-memory (default)
and ETS-buffered JSONL with periodic flush. Sessions emit
`:user_message` / `:assistant_message` / `:tool_result` events;
`Session.resume/2` rebuilds the message history from any store.
File-checkpoint snapshots fire before every `Edit` / `Write`, and
`Checkpoint.rewind/3` restores files + truncates the session log to
a chosen UUID. See [sessions + checkpoints](guides/sessions_and_checkpoints.md).

## Guides

- [Getting started](guides/getting_started.md)
- [Providers](guides/providers.md)
- [Terminal chat (mix athena.chat)](guides/tui.md)
- [Browser chat (mix athena.web)](guides/web.md)
- [Multimodal (vision)](guides/multimodal.md)
- [Gemini setup](guides/gemini.md)
- [Tool calls](guides/tool_calls.md)
- [The agent loop](guides/agent_loop.md)
- [Tools (incl. tool-result split)](guides/tools.md)
- [Memory + skills](guides/memory_and_skills.md) — v0.4
- [Compaction pipeline](guides/compaction_pipeline.md) — v0.4
- [Hooks reference](guides/hooks_reference.md) — v0.4
- [Permissions](guides/permissions.md) — v0.4
- [Agents + subagents](guides/agents_subagents.md) — v0.4
- [Sessions + checkpoints](guides/sessions_and_checkpoints.md) — v0.4

## License

Apache 2.0 — see [LICENSE](LICENSE).
