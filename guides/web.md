# Browser chat (mix athena.web)

`mix athena.web` starts a Phoenix LiveView chat UI backed by the same agent
loop as `mix athena.chat`. By default the server binds to localhost only;
pass `--lan` to reach it from a phone or a second machine on the same
network — access is then gated by a shared-secret token printed at startup.

## Prerequisites

The web UI requires three optional dependencies:

```elixir
# mix.exs
{:phoenix, "~> 1.7"},
{:phoenix_live_view, "~> 1.0"},
{:bandit, "~> 1.5"}
```

ExAthena declares them `optional: true` so the core library stays lean.
Without them, `mix athena.web` prints an error and exits.

The JS bundle is served directly from the installed Hex packages — there is no
npm or esbuild step.

## Launching

```bash
mix athena.web                  # http://localhost:4000 (this machine only)
mix athena.web --port 8080      # custom port
mix athena.web --lan            # expose on the network (token-gated)
```

### Flags

| Flag | Description |
|---|---|
| `--port PORT` | HTTP port. Default: `4000`. |
| `--lan` | Bind `0.0.0.0` instead of loopback so other devices can connect. Access requires a shared-secret token (auto-generated unless supplied). |
| `--host HOST` | Bind an explicit IP address. Non-loopback hosts are token-gated like `--lan`. |
| `--token TOKEN` | The shared secret gating access. Defaults: none on loopback, auto-generated on `--lan`/`--host`. The `ATHENA_WEB_TOKEN` env var works too. |
| `--log` | Also write log output to `log/phoenix_output.log`. |

By default the server binds `127.0.0.1` — only this machine can reach it. The
UI runs an agent with shell and file-write tools in a directory chosen from
the browser, so treat access to it as shell access. With `--lan` the startup
banner prints a tokened URL (`http://…/?token=…`); open it once per browser —
the token is then stored in the session cookie, and every page load and
websocket mount without it is rejected.

## Layout

```
┌──────────────┬────────────────────────────────────┬───────────────────────┐
│ ◈ ExAthena   │                                    │ ⚡ Reading · foo.ex   │
│              │  You: refactor the auth module      │                       │
│ Provider     │                                    │ call  read            │
│ [Ollama    ▼]│  Assistant: I'll start by …        │  └ {"path":"lib/…"}   │
│              │                                    │ result                │
│ Model        │  ● read(lib/auth.ex)               │  └ defmodule Auth…    │
│ [qwen2.5…  ▼]│    └ defmodule Auth do             │                       │
│              │      …4 more lines                  │ call  edit            │
│ Mode         │                                    │  └ {"path":"lib/…"}   │
│ [ReAct     ▼]│  ● edit(lib/auth.ex)               │ result                │
│              │    └ patch applied (14 lines)       │  └ patch applied …    │
│ + New session│                                    │                       │
│ ▼ Sessions   │  ┌─────────────────────────────┐   │                       │
│              │  │ /                           │   │                       │
│ Recent       │  └─────────────────────────────┘   │                       │
│ my_app       │                                    │                       │
└──────────────┴────────────────────────────────────┴───────────────────────┘
```

- **Sidebar** (left) — provider, model, and mode selectors; session list and
  recent projects; live token/cost status block while the model is running.
- **Messages** (center) — streaming assistant text with inline tool-call blocks
  showing collapsible output previews.
- **Details** (right) — chronological log of every tool call and result,
  thinking blocks, and iteration markers for the current session.
- **Right panels** (optional, toggled via ⊟ / ± buttons) — color-coded diff
  viewer for file edits, raw stdout for Bash calls, and a live `git diff HEAD`
  panel.

## Sidebar: provider and model selector

The sidebar dropdown lists every provider the registry knows about at startup —
the five built-in providers **plus** any JSON-defined providers loaded from
`~/.config/ex_athena/providers/`:

```
┌──────────────┐
│ Provider     │
│ ┌──────────┐ │
│ │ Ollama ▼ │ │
│ └──────────┘ │
│  llama.cpp   │
│  Ollama      │
│  Claude      │
│  OpenAI-compat│
│  Gemini      │
│  groq        │  ← JSON-defined provider
│  deepseek    │  ← JSON-defined provider
└──────────────┘
```

This is the same registry the TUI (`mix athena.chat`) reads. A provider
defined in `~/.config/ex_athena/providers/groq.json` appears in both front-ends
automatically. See [providers.md](providers.md) for the JSON schema and
example files.

Switching provider triggers an async model fetch — the model selector shows
"fetching models…" for local providers (Ollama, llama.cpp) that expose a
`/api/tags` or `/v1/models` endpoint. Cloud providers (Claude, Gemini,
OpenAI-compatible) fall back to a free-text input so you can type the model
name directly.

### Inline API key prompt

A JSON provider definition can include `"api_key_prompt": true` to tell the
web sidebar to show an inline password field for that provider whenever it is
selected:

```json
{
  "name": "my-openrouter",
  "adapter": "req_llm",
  "req_llm_provider_tag": "openai",
  "base_url": "https://openrouter.ai/api/v1",
  "api_key_prompt": true,
  "default_model": "anthropic/claude-opus-4-8"
}
```

When a user selects `my-openrouter` from the dropdown, the sidebar renders:

```
┌──────────────┐
│ Provider     │
│ [my-openrouter]
│              │
│ API key      │
│ [••••••••••] │
└──────────────┘
```

The key is held in LiveView socket state for the duration of the browser
session. It is sent to the server only over the WebSocket connection and is
never written to disk — each page load starts with an empty key field.

For providers where the key is set via `api_key_env` or `config.exs`, the
prompt field is not shown. `api_key_prompt: true` is intended for shared
deployments where different users supply their own keys.

## Session persistence

Every completed turn is auto-saved. The persistence layout under
`~/.ex_athena/web/`:

```
~/.ex_athena/web/
├── secret.key          # stable secret_key_base — generated once
├── recent.json         # recently opened project directories (max 20)
└── sessions/
    ├── <id>.session    # full session binary
    ├── <id>.session
    └── …
```

**Session files** are Erlang binary terms written with
`:erlang.term_to_binary/1`. Each file contains:

| Field | Description |
|---|---|
| `id` | UUID — stable across saves |
| `title` | First user message, truncated |
| `cwd` | Working directory for this session |
| `provider` | Provider name at save time |
| `model` | Model name at save time |
| `mode` | Agent mode at save time |
| `created_at` / `updated_at` | `DateTime.t()` |
| `display_messages` | Rendered message list for fast reload |
| `ex_messages` | Raw `ExAthena.Messages` for resuming the loop |
| `tool_uis` | Diff / file / process payloads keyed by tool call ID |
| `details_stream` | Full right-pane event log |

Sessions survive server restarts because `secret.key` persists the
`secret_key_base` — the same key is used every run, so existing browser
cookies remain valid. A fresh random key would cause the old session cookie to
fail CSRF validation, triggering a LiveView reload with a multi-second delay.

**`recent.json`** tracks the working directories you have opened, newest
first, capped at 20 entries. The sidebar "Recent" section and the empty-state
screen both read from this file.

### Loading and managing sessions

Click **▼ Sessions** in the sidebar to expand the session list. Sessions are
filtered to the active working directory; click a session title to load it, or
× to delete the file.

**Fork**: every assistant message has a `⑂ fork` button. It duplicates the
conversation history up to that point and opens a new session — the original
session is untouched.

## Features at a glance

| Feature | Description |
|---|---|
| **Streaming** | Tokens stream in real time over the LiveView WebSocket. |
| **Thinking** | Models that emit `<think>` blocks show reasoning in the details pane while the answer builds in the main area. |
| **Action indicator** | While the model runs, a `⚡ Reading · foo.ex` pill tracks the current tool call in real time. |
| **Diff viewer** | File edits show a **▼ view** button. Click it for a color-coded line diff (`+` green / `−` red) computed server-side. |
| **Bash output** | Bash tool calls show exit code, runtime, and stdout in a collapsible block. |
| **Markdown** | Completed responses render headings, fenced code blocks (with language label), inline code, bold/italic, lists, links, and horizontal rules — no CDN needed. |
| **Git panel** | The ± button opens a live `git diff HEAD` panel, refreshed after each tool result. |
| **Fork** | Snapshot any assistant message and branch the conversation from that point. |
| **Session recall** | Reload any past session; the full conversation and tool-call details restore instantly. |

## Tips

- **Working directory**: click the **+** button at the top of the sidebar (or
  select a recent project from the empty state) to open a folder. The agent's
  filesystem tools are scoped to that directory.
- **Multiple providers**: drop several JSON files into
  `~/.config/ex_athena/providers/` before starting — they all appear in the
  sidebar dropdown immediately.
- **Shared server**: start with `--lan` so team members on the same network
  can reach the UI at `http://<host-ip>:4000`, and share the tokened URL from
  the startup banner — anyone holding it can run commands on your machine.
  Use `api_key_prompt: true` in provider JSON files to let each user supply
  their own key without sharing credentials.
- **Session cleanup**: sessions accumulate in `~/.ex_athena/web/sessions/`.
  Delete them from the sidebar × button or remove `*.session` files directly.
