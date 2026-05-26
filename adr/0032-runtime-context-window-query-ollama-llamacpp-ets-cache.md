# ADR: Runtime Context-Window Query for Ollama and llama.cpp with ETS Cache

**Status:** Accepted

## Context

ExAthena's compaction budget is sized from `capabilities[:max_tokens]`. Sub-ticket 1 reads `llm_db` limits for known models, but local Ollama and llama.cpp models are not in the `llm_db` catalog (they use the generic `openai` tag pointing at a custom base_url). Without runtime querying, these models fall back to 8192, which may be smaller than the model's actual `n_ctx` (e.g. a model loaded with `--ctx-size 32768`).

## Decision

1. **Introduce `ExAthena.ContextWindow`** as a supervised GenServer. It owns an ETS table (`:ex_athena_context_window_cache`, `:set`, `:public`, `read_concurrency: true`) keyed by `{backend_atom, base_url, model_id}`.

2. **Query endpoints:**
   - Ollama: `POST {base_url}/api/show` → `model_info["<arch>.context_length"]` (find any key ending in `.context_length`)
   - llama.cpp: `GET {base_url}/props` → `default_generation_settings.n_ctx`

3. **Cache strategy:** ETS is read directly by callers (no GenServer roundtrip on hit). Cache misses serialize through `GenServer.call` with a double-check on entry (prevents duplicate HTTP requests when two callers miss simultaneously). HTTP timeout is 3 seconds. Errors are silent (`:error` → caller uses fallback). No TTL — model configs don't change at runtime.

4. **Resolution tier:** sits between llm_db lookup and the 8192 fallback in `ReqLLM.capabilities/1`. Cloud providers (anthropic, openai, google) never reach this tier because llm_db covers them.

5. **Defensive caller:** `lookup/1` wraps `GenServer.call` in `try/catch :exit` so that if the supervisor is not running (e.g. bare library use without starting the application), callers silently get `:error` and fall through to the 8192 fallback.

## Consequences

- **Positive:** Compaction now fires at the correct threshold for any Ollama/llama.cpp model, regardless of whether it's in llm_db. Context-length errors and silent truncation are eliminated for local deployments.
- **Positive:** Cloud providers are unaffected — they resolve through llm_db before reaching the runtime query path.
- **Positive:** After the first lookup per model, subsequent iterations in a loop pay zero HTTP cost (ETS read only).
- **Neutral:** A new supervised process is added to the application. It is cheap (ETS table + idle GenServer) and always on.
- **Neutral:** The HTTP query adds ~1-10ms latency to the first `capabilities/1` resolution for a local model. This happens once per run, not per iteration.
- **Negative:** If the local server is unreachable at capabilities-resolution time, the query silently fails and falls back to 8192. The server being unreachable will be caught anyway when the first LLM call is made.
