# exo Provider — Design

**Date:** 2026-06-05
**Status:** Approved

## Goal

Add [exo](https://github.com/exo-explore/exo) (distributed local LLM inference,
2025 rewrite, v1.0.x) as a first-class chat provider: selectable in the web UI
dropdown, with model listing, context-window discovery, TUI defaults, and
automatic instance activation — defaulting to the local exo interface at
`http://localhost:52415`.

## Context

`:exo` is already half-wired in the backend:

- `Config.@builtin_providers` maps `:exo` → `ExAthena.Providers.ReqLLM` with
  req_llm tag `"openai"` and `openai_compatible_backend: :exo`
  (`lib/ex_athena/config.ex:96,115,125`).
- `Providers.ReqLLM.resolve_api_key/2` already injects the placeholder key
  `"exo"` (`lib/ex_athena/providers/req_llm.ex:381`) — exo has no auth.

Missing: UI dropdown entry, default base URL, model listing, context-window
probing, TUI defaults, and handling of exo's instance lifecycle.

### Verified exo API facts (fetched from source, copies in `tmp/exo_src/`)

- Default API port **52415** (`src/exo/main.py`); no authentication.
- `GET /v1/models` — OpenAI-shaped `{"data": [{"id": ...}]}` with extras
  (`context_length`, `name`, …). `?status=downloaded` filters to models
  present in the cluster.
- Chat requires an **active instance**: `POST /v1/chat/completions` returns
  404 `{"error": {"message": "No instance found for model <id>", ...}}`
  otherwise (`_validate_model_has_instance`, `src/exo/api/main.py`).
- `POST /place_instance {"model_id": m}` activates a model. **Not
  idempotent** — posting for an already-active model creates a duplicate
  instance. Check-before-create is mandatory.
- `GET /state/instances` returns `%{instance_id => tagged_instance}` where
  tagged_instance is `{"MlxRingInstance" | "MlxJacclInstance" =>
  %{"shardAssignments" => %{"modelId" => m, ...}, ...}}` (camelCase).
- Instance registration is sub-second and is the exact predicate chat checks;
  weight loading happens afterwards (affects first-token latency only).
- Model IDs are full HuggingFace IDs (e.g.
  `mlx-community/Llama-3.2-1B-Instruct-4bit`); shown verbatim in dropdowns.

## Approaches considered

1. **Built-in module mirroring `Chat.LlamaCpp`** (chosen) — exo's API is
   OpenAI-shaped; a small `ExAthena.Chat.Exo` module plus thin touches in
   existing files finishes the job consistently with llama.cpp/Ollama.
2. JSON provider spec in `~/.config/ex_athena/providers/exo.json` — zero
   code, but invisible to the hardcoded web dropdown and per-user setup.
   Rejected.

## Design

### 1. `ExAthena.Chat.Exo` (new, mirrors `Chat.LlamaCpp`)

- `@default_base_url "http://localhost:52415"`, configurable via
  `config :ex_athena, :exo, base_url: ...`.
- `list_models/1` → `GET {base}/v1/models?status=downloaded` (downloaded-only
  so everything in the dropdown is chat-able), parse `data[*].id`, sorted.
  Errors: `:exo_unreachable | :unexpected_response | {:http, status}`.
- `ensure_instance(model, opts)`:
  1. `GET /state/instances` → `:ok` if any instance's
     `shardAssignments.modelId == model` (match either tag key).
  2. Absent → `POST /place_instance {"model_id": model}`, then poll
     `/state/instances` every 250 ms with a ~10 s cap → `:ok` or
     `{:error, :exo_instance_unavailable}`.
  - Polling over the `/instance/await` SSE stream: same readiness predicate,
    no SSE parsing, simpler to test.
- Strips `/v1` suffix from caller-provided base URLs (same as llamacpp).

### 2. Web UI (`lib/ex_athena/web/live/chat_live.ex`)

- `{"EXO", "exo"}` added to `@providers`.
- `fetch_models("exo")` clause → `Chat.Exo.list_models/1` with configured
  base URL.
- `apply_base_url(opts, "exo")` → configured or `http://localhost:52415`.

### 3. Instance auto-activation hook (`Providers.ReqLLM`)

In `query`/`stream`, when `openai_compatible_backend: :exo`, call
`Chat.Exo.ensure_instance(model, base_url: ...)` pre-flight. One hook covers
web UI, TUI, and programmatic use. Failure surfaces as a normal provider
error ("exo has no active instance for <model>"). Since the dropdown lists
downloaded-only models, activation does not trigger downloads.

### 4. ContextWindow (`lib/ex_athena/context_window.ex`)

- Guard widened to `backend in [:ollama, :llamacpp, :exo]`.
- `do_fetch(:exo, base_url, model)` → `GET /v1/models` (full catalog — the
  card is needed regardless of download filtering), find entry with
  `id == model`, return `context_length` when integer > 0, else `:error`
  (falls back to defaults as today).
- `@exo_default "http://localhost:52415"`, `configured_exo_url/0`,
  `resolve_base_url` clause.

### 5. TUI (`lib/ex_athena/chat/tui/runner.ex`)

- `provider_base_url_defaults(:exo) → {:exo, "http://localhost:52415"}`.
- `:exo_unreachable` added to the `select_initial_model/2` error spec.

## Error handling

- Unreachable exo / non-200 / malformed body in `list_models` → empty
  dropdown (same UX as ollama/llamacpp today).
- `ensure_instance` failure → provider error string surfaced in chat UI.
- ContextWindow miss → `:error` → existing default fallbacks.

## Testing (TDD, Bypass-based)

- `test/ex_athena/chat/exo_test.exs`:
  - `list_models/1`: sends `status=downloaded` query param; parses and sorts
    ids; unreachable / non-200 / malformed body errors; `/v1` suffix
    normalization; config fallback.
  - `ensure_instance/2`: already-active → no create POST issued; absent →
    posts `place_instance` then polls to ready; never-ready → timeout error;
    parses both `MlxRingInstance` and `MlxJacclInstance` tags.
- ContextWindow: exo fetch extracts `context_length`; 0/missing → `:error`.
- Integration: `Providers.ReqLLM.query` with backend `:exo` against Bypass
  pre-flights activation before `POST /v1/chat/completions`.

## Out of scope

- Surfacing weight-load/download progress (`/state/runners`,
  `/state/downloads`) in the UI.
- exo's Anthropic/Ollama-compatible endpoints (`/v1/messages`,
  `/ollama/api/*`).
