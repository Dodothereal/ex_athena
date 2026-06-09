# 08 · Permissions — The Deny-First Gate

> **What this answers:** how does ExAthena decide whether a tool call is allowed? What's a "phase"? When does the `can_use_tool` callback fire?
> **Audience:** consumers configuring safety; contributors maintaining the gate.

---

## The check chain

```mermaid
flowchart TD
  start([Permissions.check tc ctx opts]) --> step1{disallowed_tools<br/>contains name?}
  step1 -- yes --> deny1[deny user_denied]
  step1 -- no --> trustHatch{phase == :trusted<br/>and respect_denylist == false?}
  trustHatch -- yes --> skipDeny[skip disallow]
  trustHatch -- no --> step2
  skipDeny --> step2{allowed_tools set<br/>and name not in it?}
  step2 -- yes --> deny2[deny user_denied]
  step2 -- no --> step3{phase}
  step3 -- :plan --> phasePlan{name in @readonly_tools?}
  phasePlan -- yes --> step4
  phasePlan -- no --> phaseGated{name in @mutating_tools?}
  phaseGated -- yes --> deny3[deny phase_gated]
  phaseGated -- no --> step4
  step3 -- :default --> step4
  step3 -- :accept_edits --> step4
  step3 -- :trusted --> allowT[allow]
  step3 -- :bypass_permissions --> allowB[allow]
  step4{can_use_tool callback set?}
  step4 -- no --> allow[allow]
  step4 -- yes :default --> cb[invoke callback]
  step4 -- yes :accept_edits<br/>and name in auto_allow set --> allow
  step4 -- yes :accept_edits<br/>and name NOT in auto_allow --> cb
  cb -- :allow / {:allow, _} --> allow
  cb -- :deny / {:deny, _} --> deny4[deny user_denied]
  cb -- :halt / {:halt, _} --> halt[halt]

  classDef denial fill:#fecaca,stroke:#991b1b;
  classDef allow fill:#bbf7d0,stroke:#065f46;
  class deny1,deny2,deny3,deny4 denial
  class allow,allowT,allowB allow
```

Source: [`ExAthena.Permissions.check/3`](../lib/ex_athena/permissions.ex#L126).

**Deny-first ordering**: `disallowed → allowed → phase → callback`. First decisive answer wins.

The denylist is the user's "absolutely never" list — it survives even `:bypass_permissions`. The only escape hatch is `:trusted` with `respect_denylist: false`, intended for *very* trusted automation contexts.

---

## The five phases

| Phase | Read-only tools | Write/edit/bash | `can_use_tool` consulted | Use case |
|---|---|---|---|---|
| `:plan` | ✅ | ❌ phase_gated (`todo_write` ✅) | only if not auto-allowed | Read-only investigation before code changes. Mirrors the agent's "plan mode." `todo_write` is allowed — it mutates only session bookkeeping, so orchestrate planning and read-only workers can record their plan. |
| `:default` | ✅ | ✅ via callback | ✅ for everything | Interactive sessions where the user approves writes one-by-one. |
| `:accept_edits` | ✅ | ✅ for write/edit/todo_write/read/glob/grep/web_fetch/plan_mode/spawn_agent | ✅ for everything else (bash, custom) | "Edits are pre-approved" — file mutations auto-allow; shell + custom still ask. |
| `:trusted` | ✅ | ✅ | ❌ (always allow) | Trusted automation; denylist still wins unless `respect_denylist: false`. |
| `:bypass_permissions` | ✅ | ✅ | ❌ | Test harnesses, sandboxed runners. Denylist still wins. |

Phase comes from `ctx.phase` (which the Loop sets from `opts[:phase]`, default `:default`).

### Read-only tools (allowed in `:plan`)

From [`@readonly_tools`](../lib/ex_athena/permissions.ex#L100):
`read`, `glob`, `grep`, `web_fetch`, `plan_mode`, `spawn_agent`, `lsp`.

### Mutating tools (denied in `:plan`)

From [`@mutating_tools`](../lib/ex_athena/permissions.ex#L101):
`write`, `edit`, `bash`.

`todo_write` is **not** here: it mutates only session bookkeeping (the todo
list), never the workspace, so `check_phase/3` allows it in `:plan`.

### Auto-allowed in `:accept_edits`

From [`@auto_allow_in_accept_edits`](../lib/ex_athena/permissions.ex#L105):
`read`, `glob`, `grep`, `web_fetch`, `plan_mode`, `spawn_agent`, `write`, `edit`, `todo_write`.

(Note: `bash` is **not** auto-allowed in `:accept_edits` — it still consults the callback. Custom tools are also gated.)

---

## The `can_use_tool` callback

```elixir
ExAthena.run(prompt,
  phase: :default,
  can_use_tool: fn name, args, ctx ->
    cond do
      name == "bash" and dangerous?(args["command"]) -> {:deny, "Won't run rm -rf"}
      name == "web_fetch" -> :allow
      true -> ask_user(name, args)
    end
  end
)
```

Callback signature:

```elixir
(name :: String.t(), arguments :: map(), ctx :: ToolContext.t()) ->
  :allow | {:allow, term()} |
  :deny  | {:deny, %Denial{}} | {:deny, term()} |
  :halt  | {:halt, term()}
```

Returns are normalised by [`normalize/1`](../lib/ex_athena/permissions.ex#L234):

- `:allow` / `{:allow, _}` → `:allow`
- `:deny` → `{:deny, %Denial{code: :user_denied}}`
- `{:deny, %Denial{}}` → passed through
- `{:deny, term}` → wrapped in `Denial{code: :user_denied, metadata: %{raw: term}}`
- `:halt` / `{:halt, _}` → terminates the loop with `:error_halted`
- anything else → `{:deny, %Denial{code: :unknown}}`

---

## The Denial struct

```mermaid
classDiagram
  class Denial {
    +reason: string
    +code: :phase_gated | :budget_exceeded | :user_denied | :sandbox_violation | :unknown
    +metadata: map
  }
```

Source: [`Permissions.Denial`](../lib/ex_athena/permissions.ex#L1).

Codes:

| Code | Meaning |
|---|---|
| `:phase_gated` | Tool blocked by phase (e.g. write in `:plan`). |
| `:budget_exceeded` | Budget check killed it (reserved). |
| `:user_denied` | Denylist, allowlist, or `can_use_tool` returned `:deny`. |
| `:sandbox_violation` | Sandbox / worktree boundary violated. |
| `:unknown` | Callback returned something unexpected. |

`metadata` often carries `requested_tool`, `allowed_tools`, `phase`, and any raw `:deny` reason under `metadata.raw`. The `String.Chars` impl returns `reason`, so `to_string(denial)` still works for legacy callers.

---

## Permissions and hooks

The Mode wraps a tool call in three checks:

```mermaid
sequenceDiagram
  participant M as Mode
  participant Perm as Permissions
  participant H as Hooks

  M->>Perm: check(tc, ctx, opts)
  alt :allow
    M->>H: PreToolUse(tc.name, args, tc.id)
    alt :ok
      M->>M: PermissionRequest hook (informational)
      M->>M: execute
    else {:deny, r} | {:halt, r}
      M->>H: PermissionDenied (informational)
      M->>M: synth deny tool_result
    end
  else {:deny, denial}
    M->>H: PermissionDenied (informational)
    M->>M: synth deny tool_result
  else {:halt, r}
    M-->>M: terminate :error_halted
  end
```

`PermissionRequest` and `PermissionDenied` are informational lifecycle events. They can't reverse the decision (the gate already ran), but they're useful for logging and audit.

---

## Examples

### Read-only investigation (`:plan`)

```elixir
ExAthena.run("Find every place we open the DB", phase: :plan)
# bash, write, edit all denied with code: :phase_gated (todo_write is allowed).
```

### Code-mod session with auto-write

```elixir
ExAthena.run("Rename Foo to Bar throughout the repo",
  phase: :accept_edits,
  can_use_tool: fn
    "bash", %{"command" => "git " <> _}, _ -> :allow
    "bash", _, _ -> {:deny, "Shell only allowed for git in this session"}
    _, _, _ -> :allow
  end
)
```

### Hard-deny denylist that survives bypass

```elixir
ExAthena.run("Do whatever you need to",
  phase: :bypass_permissions,
  disallowed_tools: ["bash"]   # still wins
)
```

### Trusted automation (skip the denylist too)

```elixir
ExAthena.run("Run the nightly migration",
  phase: :trusted,
  respect_denylist: false
)
```

---

## Contributor notes

- **Deny-first ordering is a hard invariant**: never swap the order in `check/4`. Tests in [`test/ex_athena/permissions_test.exs`](../test/ex_athena/permissions_test.exs) enforce it.
- **`:auto` is reserved**: do not introduce a phase named `:auto`. It's reserved for the future ML-classifier mode (Claude Code paper terminology).
- **Phase ≠ permission**: phase is the *prevailing posture*. The denylist is *user veto*. Don't conflate them in error messages.
- **The callback gets `ctx`**: include `ctx.session_id` and `ctx.assigns` when you need to consult the session's UI for an approval — that's why `ToolContext` is the third arg.
- **Halt vs deny**: returning `:halt` from the callback stops the entire run. Reserve it for "user closed the dialog" or "operator killed the session." Deny just blocks this call and lets the model try something else.

---

## Where to go next

- [`guides/permissions.md`](../guides/permissions.md) — practical setup and callback patterns.
- [09 · Hooks](09-hooks.md) — `PermissionRequest`, `PermissionDenied`, `ToolDenied` informational events.
- [13 · Agents & subagents](13-agents-and-subagents.md) — agents can override phase / allowlist per subagent.
