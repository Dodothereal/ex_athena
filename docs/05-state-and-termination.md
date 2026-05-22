# 05 · State & Termination

> **What this answers:** what does `Loop.State` carry? What are the 12 finish reasons and how should they be classified?
> **Audience:** contributors (state invariants); consumers (interpreting `Result.finish_reason`).

---

## Loop.State at a glance

```mermaid
classDiagram
  class Loop_State {
    +messages: [Message]
    +tool_specs: [Tool.Spec]
    +capabilities: map
    +provider_mod: module
    +provider_opts: keyword
    +request_template: Request
    +permissions_opts: map
    +hooks: map
    +ctx: ToolContext
    +on_event: function
    +budget: Budget
    +max_iterations: int = 25
    +max_consecutive_mistakes: int = 3
    +max_budget_usd: float?
    +max_unproductive_iterations: int = 3
    +tool_timeout_ms: int = 60_000
    +max_concurrency: int = 4
    +iterations: int
    +tool_calls_made: int
    +consecutive_mistakes: int
    +unproductive_iterations: int
    +last_tool_fingerprint: list?
    +no_progress_snapshot: [Message]?
    +mode: module
    +mode_state: map
    +halted_reason: term?
    +session_id: string
    +parent_session_id: string?
    +meta: map
  }

  class Budget {
    +usage: map
    +cost_usd: float
  }

  class ToolContext {
    +cwd: string
    +phase: atom
    +session_id: string
    +assigns: map
    +metadata: map
  }

  class Message {
    +role: atom
    +content: string | parts
    +tool_calls: [ToolCall]?
    +tool_results: [ToolResult]?
    +name: string?
    +pin: boolean
  }

  Loop_State --> Budget
  Loop_State --> ToolContext
  Loop_State "1" --> "*" Message
```

Source: [`lib/ex_athena/loop/state.ex`](../lib/ex_athena/loop/state.ex). State is *opaque* — only `Loop.Mode` implementations receive it. Consumers see `ExAthena.Result` ([`lib/ex_athena/result.ex`](../lib/ex_athena/result.ex)).

### Field roles

| Field | Role |
|---|---|
| `messages` | Running conversation. Grows each turn. Compacted between turns. |
| `tool_specs` | Resolved tool list — builtin + MCP. Stable across the run unless a `ChatParams` hook rewrites it. |
| `capabilities` | Provider capabilities (`max_tokens`, `native_tool_calls`, `streaming`, multimodal flags). Used by tool-call parser tier selection. |
| `provider_mod`, `provider_opts` | Where to call. |
| `request_template` | Base `Request` overlaid each iteration with current messages + tool schemas. |
| `permissions_opts` | `phase`, `allowed_tools`, `disallowed_tools`, `can_use_tool`. Fed to [`Permissions.check/3`](../lib/ex_athena/permissions.ex). |
| `hooks` | Lifecycle hook table. |
| `ctx` | `ToolContext` — cwd, phase, session_id, assigns. Threaded to every `Tool.execute/2`. |
| `on_event` | Optional stream-event callback. |
| `budget` | Accumulating token + cost usage. |
| `max_iterations` etc. | Kernel caps. |
| `iterations`, `tool_calls_made`, `consecutive_mistakes`, `unproductive_iterations` | Kernel counters. |
| `last_tool_fingerprint` | Sorted `[{name, json_args}]` from previous turn — drives no-progress detection. |
| `no_progress_snapshot` | Snapshot of stuck messages, attached to Result when `:error_no_progress` fires. |
| `mode`, `mode_state` | Strategy module + its private state. |
| `halted_reason` | Populated when a hook / tool returned `{:halt, r}`. |
| `session_id`, `parent_session_id` | Stable run identity + subagent linkage. |
| `meta` | Open extension point for compactor knobs (`auto_pin`, `reactive_compact`, `pinned_prefix_count`, …), mode keys, hook outputs (`early_halt`). |

---

## Twelve termination subtypes

Source: [`lib/ex_athena/loop/terminations.ex`](../lib/ex_athena/loop/terminations.ex).

```mermaid
stateDiagram-v2
  state "Run" as run
  run --> stop: :stop
  state "Capacity" as cap {
    [*] --> error_max_turns
    [*] --> error_max_budget_usd
    [*] --> error_max_structured_output_retries
    [*] --> error_consecutive_mistakes
    [*] --> error_no_progress
    [*] --> error_prompt_too_long
  }
  state "Retryable" as ret {
    [*] --> error_during_execution
    [*] --> error_schema_validation
  }
  state "Fatal" as fat {
    [*] --> error_halted
    [*] --> error_compaction_failed
    [*] --> error_provider_auth
  }
  run --> cap
  run --> ret
  run --> fat
  stop: :success category
```

### Category table

| Subtype | Category | When it fires | Where set |
|---|---|---|---|
| `:stop` | `:success` | Model returned text with no tool calls. | [`react.ex:98`](../lib/ex_athena/modes/react.ex#L98) |
| `:error_max_turns` | `:capacity` | `iterations >= max_iterations`. | [`loop.ex:125`](../lib/ex_athena/loop.ex#L125) |
| `:error_max_budget_usd` | `:capacity` | `Budget.exceeded?` for `max_budget_usd`. | [`loop.ex:133`](../lib/ex_athena/loop.ex#L133) |
| `:error_max_structured_output_retries` | `:capacity` | Structured extraction repair budget exhausted. | `Structured` |
| `:error_consecutive_mistakes` | `:capacity` | `consecutive_mistakes >= max`. | [`loop.ex:129`](../lib/ex_athena/loop.ex#L129) |
| `:error_no_progress` | `:capacity` | `unproductive_iterations >= max` with guard > 0. Carries `no_progress_snapshot`. | [`loop.ex:140`](../lib/ex_athena/loop.ex#L140) |
| `:error_prompt_too_long` | `:capacity` | Reactive compact failed or still too large. | [`loop.ex:190`](../lib/ex_athena/loop.ex#L190) |
| `:error_during_execution` | `:retryable` | Mode returned `{:error, reason}` not handled specially. | [`loop.ex:161`](../lib/ex_athena/loop.ex#L161) |
| `:error_schema_validation` | `:retryable` | Structured output failed schema; `error_diagnostic` carries detail. | `Structured` |
| `:error_halted` | `:fatal` | Hook or tool returned `{:halt, reason}`; `meta.early_halt` is set. | [`loop.ex:121`](../lib/ex_athena/loop.ex#L121) |
| `:error_compaction_failed` | `:fatal` | Compactor returned `{:error, _}`. | [`loop.ex:167`](../lib/ex_athena/loop.ex#L167) |
| `:error_provider_auth` | `:fatal` | Provider returned HTTP 401 / 403. | Provider adapter |

### Classification helpers

```elixir
ExAthena.Loop.Terminations.category(:stop)               # => :success
ExAthena.Loop.Terminations.category(:error_max_turns)    # => :capacity
ExAthena.Loop.Terminations.category(:error_halted)       # => :fatal
ExAthena.Loop.Terminations.success?(:stop)               # => true
ExAthena.Loop.Terminations.error?(:error_max_turns)      # => true
ExAthena.Loop.Terminations.all()                         # => [:stop, …]
```

See [17 · Error recovery](17-error-recovery.md) for the caller-side playbook for each category.

---

## State invariants

```mermaid
flowchart LR
  inv1[messages grows only<br/>or is replaced by Compactor]
  inv2[iterations monotonically<br/>increases by 1 per :continue]
  inv3[tool_calls_made monotonically<br/>increases by len of tool_calls]
  inv4[consecutive_mistakes<br/>reset to 0 on tool success]
  inv5[finish_reason set exactly once<br/>at terminal state]
  inv6[messages always end in tool_result<br/>if tool calls happened this turn]
```

Concretely:

- `iterations` grows by 1 per `{:continue, _}` ([`loop.ex:150`](../lib/ex_athena/loop.ex#L150)).
- `tool_calls_made` grows by the number of tool calls in the turn ([`react.ex:115`](../lib/ex_athena/modes/react.ex#L115)).
- `consecutive_mistakes` is reset to 0 by `Modes.ReAct` on any successful tool execution ([`react.ex:118`](../lib/ex_athena/modes/react.ex#L118)).
- `finish_reason` lives in `meta` and is written via `Loop.set_finish_reason/2` ([`loop.ex:356`](../lib/ex_athena/loop.ex#L356)). Once set, the loop exits.
- `Loop.State` is a struct — every step returns a new copy. No in-place mutation.

---

## Result struct — public face of terminal state

```mermaid
classDiagram
  class Result {
    +text: string?
    +messages: [Message]
    +finish_reason: subtype
    +halted_reason: term?
    +error_diagnostic: map?
    +iterations: int
    +tool_calls_made: int
    +usage: map?
    +cost_usd: float?
    +duration_ms: int
    +model: string?
    +provider: module?
    +no_progress_snapshot: [Message]?
    +telemetry: map
  }
```

Built in [`Loop.to_result/2`](../lib/ex_athena/loop.ex#L422). The text is the last assistant message's content ([`extract_final_text/1`](../lib/ex_athena/loop.ex#L479)).

`category/1` lives on the Result struct or you can call `Loop.Terminations.category(result.finish_reason)`.

---

## Contributor notes

- **State field churn**: each new field added to `State` must be defaulted in `defstruct` and noted in the `@type t :: %__MODULE__{…}` block. Tests load fresh state via `%State{}` so default values matter.
- **`meta` over new fields**: when in doubt, add a key to `meta` instead of growing the struct. Mode keys, compactor knobs, and hook outputs all live there.
- **Don't read `halted_reason` to detect "did this halt"**: `halted_reason` is just an optional explanation. The authoritative signal is `meta.finish_reason`, surfaced as `Result.finish_reason`.
- **Pinning**: `Message.pin = true` tells the compactor "never drop me." Set via `meta.auto_pin` or explicit pin in your message list. See [`apply_auto_pin/1`](../lib/ex_athena/loop.ex#L243).
- **Generated session id**: when `:session_id` isn't passed, the kernel generates a 16-byte URL-safe random string ([`generate_session_id/0`](../lib/ex_athena/loop.ex#L647)). Tests that need stability should pass one.

---

## Where to go next

- [17 · Error recovery](17-error-recovery.md) — what to do with each finish reason.
- [03 · Reasoning loop](03-reasoning-loop.md) — see the kernel write these fields.
- [12 · Compaction](12-compaction.md) — how `pin` and `meta.auto_pin` are honored.
