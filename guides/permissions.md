# Permissions (v0.4)

Every tool call goes through `ExAthena.Permissions.check/4` before
execution. The check has four layers, evaluated in this order — first
decisive answer wins:

```
1. :disallowed_tools  → denylist (always denies, deny-first)
2. :allowed_tools     → allowlist (denies anything not in it)
3. ctx.phase          → permission mode (see below)
4. :can_use_tool      → caller-supplied callback (interactive approval)
```

## Five modes

The permission mode lives at `ctx.phase` (configured via `:phase`
opt). Five modes ship; one name (`:auto`) is reserved.

### `:plan`

Read-only, **deny-by-default**. Only tools known to be read-only run:
the read-only builtins (`Read`, `Glob`, `Grep`, `WebFetch`, `WebSearch`,
`UsageRules`, `PlanMode`, `SpawnAgent`, `Lsp`), the session-control
tools (`TodoWrite`, `AskUser`, `Finish` — they mutate only session
bookkeeping), and `Bash` invocations the allowlist classifier recognises
as read-only (`cat`, `ls`, `grep`, `git log`, … — unknown commands and
interpreter one-liners are treated as mutating). Everything else —
`Write`, `Edit`, `ApplyPatch`, and every custom/MCP tool that hasn't
declared itself read-only — is denied with `code: :phase_gated`.

Read-only custom tools opt in via the optional `read_only?/0` callback
on the tool module, the MCP `annotations.readOnlyHint`, or the
`readonly_tools: ["name", …]` loop option.

```elixir
ExAthena.run("explore the repo", tools: :all, phase: :plan)
```

The agent uses the `PlanMode` tool to request a transition out of
`:plan` (typically into `:default`). When the run was *started* in
`:plan`, that exit requires `can_use_tool` approval — and is denied
outright when no callback is configured, so a host-pinned read-only run
stays read-only. When the agent entered `:plan` itself from a looser
phase, exiting merely restores the original grant and needs no
approval.

### `:default`

The standard mode. Read + write + shell, but the `:can_use_tool`
callback (if supplied) can prompt for approval.

```elixir
can_use_tool = fn name, args, _ctx ->
  case name do
    "bash" -> ask_user("Run `#{args["command"]}`?")
    _ -> :allow
  end
end

ExAthena.run("ship it", tools: :all, phase: :default, can_use_tool: can_use_tool)
```

The callback returns `:allow`, `:deny`, or `{:deny, reason}`.

### `:accept_edits`

Auto-allow file edits + read-only tools without prompting. Still
consults `can_use_tool` for `bash` and custom tools.

Auto-allow set: `read`, `glob`, `grep`, `web_fetch`, `plan_mode`,
`spawn_agent`, `write`, `edit`, `todo_write`.

```elixir
ExAthena.run("refactor the file", tools: :all, phase: :accept_edits)
```

The right mode for "I trust you to edit code, ask me before running
shell commands". Common in CI / automated workflows.

### `:trusted`

Skip the `can_use_tool` callback for every tool. Still respects the
denylist by default — `respect_denylist: false` opts out of even the
denylist (the only way to fully bypass it).

```elixir
# Trust everything except `bash`
ExAthena.run("CI agent",
  tools: :all,
  phase: :trusted,
  disallowed_tools: ["bash"])

# Full YOLO — explicit opt-in
ExAthena.run("sandbox automation",
  tools: :all,
  phase: :trusted,
  respect_denylist: false)
```

`:trusted` replaces what other tools call "auto" or "yolo" mode. The
name `:auto` is **reserved** for a future ML-based safety classifier
that the [Claude Code paper](https://arxiv.org/abs/2604.14228)
documents — don't use it.

### `:bypass_permissions`

Skip the callback AND auto-allow every tool — but **the denylist still
wins**. Locked in a doctest:

```elixir
iex> alias ExAthena.{Permissions, ToolContext}
iex> alias ExAthena.Messages.ToolCall
iex> tc = %ToolCall{id: "1", name: "bash", arguments: %{}}
iex> ctx = ToolContext.new(cwd: "/tmp", phase: :bypass_permissions)
iex> Permissions.check(tc, ctx, %{disallowed_tools: ["bash"]})
{:deny, {:disallowed, "bash"}}
```

Use this for fully unattended runs where you've explicitly enumerated
the deny list.

## Deny-first ordering

The denylist is the user's "absolutely never" list. It always runs
first. The doctest also locks `:allowed_tools` precedence over a
permissive callback:

```elixir
iex> alias ExAthena.{Permissions, ToolContext}
iex> alias ExAthena.Messages.ToolCall
iex> tc = %ToolCall{id: "1", name: "bash", arguments: %{}}
iex> ctx = ToolContext.new(cwd: "/tmp", phase: :default)
iex> opts = %{allowed_tools: ["read"], can_use_tool: fn _, _, _ -> :allow end}
iex> Permissions.check(tc, ctx, opts)
{:deny, {:not_in_allowlist, "bash"}}
```

## `can_use_tool` callback contract

Function arity 3:

```elixir
@type can_use_tool ::
  (tool_name :: String.t(), arguments :: map(), ctx :: ToolContext.t() ->
     :allow
     | {:allow, term()}
     | :deny
     | {:deny, reason :: term()})
```

Return values are normalised:

| Return | Effect |
|---|---|
| `:allow` / `{:allow, _}` | Tool executes |
| `:deny` | Becomes `{:deny, :denied_by_callback}` |
| `{:deny, reason}` | Reason flows to the model as a tool-result error |
| anything else | Becomes `{:deny, {:unexpected_callback_result, value}}` |

When the callback denies, the loop:

1. Fires the `PermissionDenied` hook with `tool_name`, `tool_use_id`,
   `arguments`, `reason`.
2. Replays a tool-result message with `is_error: true` and content
   `"permission denied: #{inspect(reason)}"`.
3. Continues the loop — the model sees the deny reason and adjusts.

This is Claude Code's "deny as routing signal" pattern.

## Skill-scoped permissions

A skill's frontmatter `allowed-tools` field restricts which tools can
run while that skill is loaded into context:

```markdown
---
name: deploy
description: Ship to production
allowed-tools: [bash, read]
---
```

When the skill is active, `Permissions.check/4` consults the
`state.active_skills` map; only `bash` and `read` are permitted for
the duration of the skill being in context. Falls back to the normal
phase-based check when no skill is active or the active skill has no
`allowed-tools` set. See [memory + skills](memory_and_skills.md).

## See also

- [`ExAthena.Permissions`](https://hexdocs.pm/ex_athena/ExAthena.Permissions.html)
- [Hooks reference](hooks_reference.md) — `PermissionRequest` /
  `PermissionDenied` payload shapes.
- [Agents + subagents](agents_subagents.md) — `permissions:` in agent
  frontmatter sets the subagent's mode.
