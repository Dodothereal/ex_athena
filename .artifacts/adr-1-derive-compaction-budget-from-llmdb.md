# ADR: Derive compaction budget from llm_db context limits

**Status:** Accepted

## Context

`ExAthena.Providers.ReqLLM.capabilities/0` returns `max_tokens: 200_000` for every model regardless of the model's actual context window. The loop uses this value as the compaction budget, triggering compaction at ~120k tokens (60% of 200k). Local small-context models (Ollama / llama.cpp, typically 4k–32k) overflow their real window before compaction fires, causing silent truncation or provider errors.

`llm_db` — already a transitive dependency via `req_llm` — carries `limits.context` per model, indexed by `{provider_atom, model_id}`. The fix reads this value to size the budget correctly.

The `ExAthena.Provider` behaviour currently defines only a zero-arity `capabilities/0` callback, giving the provider no access to the resolved model or opts at capabilities-declaration time.

## Decision

1. **Add an optional `capabilities/1` callback** to the `ExAthena.Provider` behaviour. The callback accepts the per-call opts keyword list (which, after `Config.pop_provider!/1`, includes `:req_llm_provider_tag` and `:model`) so the provider can perform a model-aware catalog lookup.

2. **Implement `capabilities/1` in `ReqLLM`** by calling `LLMDB.model(provider_atom, model_id)` and extracting `model.limits[:context]`. On any miss (model not in catalog, nil limits, non-positive context, unresolvable atom), return the base `capabilities/0` map unchanged.

3. **Change the static fallback in `capabilities/0`** from `max_tokens: 200_000` to `max_tokens: 8_192`. This conservative value ensures that when neither llm_db nor a caller override supplies a context window, compaction fires early (at ~4.9k tokens) rather than at ~120k.

4. **Update `Loop.build_initial_state/2`** to dispatch to `capabilities/1(opts)` when the provider exports it, falling back to `capabilities/0` for providers that only implement the original callback. The caller's `capabilities: %{max_tokens: N}` option remains the top priority via the existing `Map.merge`.

5. **No changes to `maybe_compact/1` or `force_compact/1`**: they already read `state.capabilities[:max_tokens] || 128_000`; only the *source* of that value changes.

6. **Add `compact_tool_schemas` to `ExAthena.Capabilities.t()`** typespec (it was already declared in `ReqLLM.capabilities/0` but missing from the type definition).

## Priority chain (lowest → highest)

| Priority | Source | Example |
|---|---|---|
| 1 (lowest) | `capabilities/0` static base | `max_tokens: 8_192` |
| 2 | `capabilities/1` llm_db lookup | `max_tokens: 200_000` (claude-opus) |
| 3 (highest) | Caller `capabilities:` opt | `capabilities: %{max_tokens: 4096}` |

## Consequences

### Positive
- Compaction fires at the right threshold for small local models (e.g. 8192 × 0.6 = ~4915 tokens for unknown Ollama models vs ~120k previously).
- Cloud models (Anthropic, OpenAI, Google) retain their real large context windows via llm_db.
- Caller `capabilities:` override continues to win — no breaking change for existing users.
- Full backward compatibility for custom `ExAthena.Provider` implementations that only implement `capabilities/0`.

### Negative / trade-offs
- Models configured via `Application.get_env` (not per-call opts) are absent from opts at capability-resolution time and therefore fall back to 8192. This is acceptable and conservative — sub-ticket 2 addresses runtime queries for local providers.
- The `strip_provider_prefix` logic is duplicated between `build_model_spec/2` and `resolve_llmdb_context/1`. They operate at different abstraction layers (model spec building vs catalog lookup), so extraction is deferred to a third use case.
- Tests that exercise the llm_db happy path require the catalog to be loaded (`LLMDB.load()` in setup), coupling those tests to the packaged snapshot.
