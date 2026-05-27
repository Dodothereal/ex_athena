# ADR: Built-in `finish` Tool for Structured Phase/Task Completion

## Status
Accepted

## Context

Consumers (e.g. `udin_code`) need a reliable, provider-agnostic signal that
the agent has produced its deliverable and the current phase is done. The loop
previously terminated only on:

- Tool exhaustion (model returns plain text → `:stop`)
- Error caps (`:error_max_turns`, `:error_no_progress`, etc.)

The `udin_code` client bolted a free-text sentinel (`~~~phase_complete~~~`)
onto the prompt for non-Claude/local models, but weak local models (qwen3.5
via Ollama) frequently never emit it, causing the loop to run indefinitely.

## Decision

Add a built-in `finish` tool (`ExAthena.Tools.Finish`) that the model calls to
declare completion. The tool:

1. Accepts optional `deliverable` and `summary` arguments.
2. Returns `{:halt, {:submitted, deliverable}}` to the loop kernel.
3. The loop kernel detects this specific halt reason in `to_result/2`,
   reclassifies it as `finish_reason: :submitted` (a success subtype), and
   surfaces the deliverable on `Result.deliverable`.

A new `:submitted` termination subtype is added to `ExAthena.Loop.Terminations`:
- `success?(:submitted) → true`
- `error?(:submitted) → false`
- `category(:submitted) → :success`

A `{:submitted, deliverable}` event is emitted to `on_event` just before
`{:done, result}` so streaming consumers can react immediately.

The `Result.deliverable` field carries the payload. `Result.halted_reason`
is set to `nil` for `:submitted` (consistent with its documented semantics:
"nil for all terminations except `:error_halted`").

## Alternatives considered

**Option B — `response_format` / structured output**: Requires the provider to
support structured output natively. Degrades silently on providers that ignore
`response_format`. The `finish` tool works wherever tool calls are supported.

**Free-text sentinel in the prompt**: Already proven fragile for weak local
models. Text sentinels are parsing heuristics; tool calls are structural
contracts.

**Per-consumer halt hook**: Works but pushes the problem to every consumer
rather than solving it once in the library.

## Consequences

- The finish tool is in `@builtins`, so it is available to all loops that use
  the default `:all` tool set. Consumers who do not want it can exclude it
  via `tools: [...]` without `ExAthena.Tools.Finish`.
- `fire_terminal_hooks` treats `:submitted` like `:stop` — it fires the
  `:Stop` lifecycle hook, not `:StopFailure`. This lets consumers attach
  cleanup/notification logic to successful completions uniformly.
- `Result.success?/1` and `Result.category/1` both treat `:submitted` as
  success, so existing retry classifiers continue to work correctly.
- Consumers migrate from free-text sentinels to `tools: [ExAthena.Tools.Finish]`
  plus a system-prompt instruction; they then check `result.finish_reason ==
  :submitted` and `result.deliverable` instead of parsing text.
