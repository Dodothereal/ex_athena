# 18 · End-to-End Traces

> **What this answers:** what does a real turn look like? Six annotated sequence diagrams of real flows.
> **Audience:** everyone. The fastest way to build a mental model.

---

## Trace 1 — Single tool call (`read mix.exs`)

```mermaid
sequenceDiagram
  autonumber
  participant U as User
  participant L as Loop
  participant H as Hooks
  participant R as ReAct
  participant P as Provider (Claude)
  participant Tc as ToolCalls
  participant Perm as Permissions
  participant T as Tools.Read

  U->>L: run("read mix.exs", provider: :claude, tools: :all)
  L->>L: build_initial_state — discover AGENTS.md, skills
  L->>H: SessionStart
  L->>H: UserPromptSubmit (no transform)

  Note over L,R: iteration 1
  L->>R: iterate(state)
  R->>H: ChatParams
  R->>P: query(Request)
  P-->>R: Response.text = "I'll read it." + tool_calls=[Read{file_path: "mix.exs"}]
  R->>Tc: extract → [{name: "read", args: %{"file_path" => "mix.exs"}}]
  R->>R: append assistant msg with tool_call
  R->>Perm: check(tc, ctx, opts) → :allow
  L->>H: PermissionRequest
  R->>H: PreToolUse(read) → :ok
  R->>T: execute(%{"file_path" => "mix.exs"}, ctx)
  T-->>R: {:ok, "<file content>"}
  R->>H: PostToolUse(read) → :ok
  R->>R: append tool_result msg
  R-->>L: {:continue, state}

  Note over L,R: iteration 2
  L->>R: iterate(state)
  R->>P: query(Request with full history)
  P-->>R: Response.text = "mix.exs declares ex_athena v0.11..." + tool_calls=[]
  R->>R: append assistant msg
  R->>R: set finish_reason :stop
  R-->>L: {:halt, state}

  L->>L: to_result/2
  L->>H: Stop
  L->>H: SessionEnd
  L-->>U: {:ok, %Result{text: "mix.exs declares ex_athena v0.11...", iterations: 2, tool_calls_made: 1, finish_reason: :stop}}
```

**What to notice:**

- Two iterations: one for the tool call, one for the final answer.
- `consecutive_mistakes` reset to 0 on the successful tool execution ([`react.ex:118`](../lib/ex_athena/modes/react.ex#L118)).
- `Stop` hook fires before `SessionEnd`.

---

## Trace 2 — Parallel multi-tool turn (read + grep concurrently)

```mermaid
sequenceDiagram
  autonumber
  participant L as Loop
  participant R as ReAct
  participant P as Provider
  participant Par as Loop.Parallel
  participant T1 as Tools.Read
  participant T2 as Tools.Grep

  L->>R: iterate(state)
  R->>P: query(Request)
  P-->>R: Response.text="Let me investigate..." + tool_calls=[Read{mix.exs}, Grep{":ex_athena", "mix.exs"}]
  R->>R: append assistant msg with both tool_calls
  R->>Par: run([Read, Grep], state, &run_single_tool_call/2)
  Par->>Par: partition by parallel_safe? — both true
  par async_stream
    Par->>T1: execute(%{"file_path" => "mix.exs"}, ctx)
    T1-->>Par: {:ok, content}
  and
    Par->>T2: execute(%{"pattern" => ":ex_athena", "file_path" => "mix.exs"}, ctx)
    T2-->>Par: {:ok, "line 8: ..."}
  end
  Par-->>R: {:ok, [tool_result_read, tool_result_grep], state}
  R->>R: append both tool_results in tool_calls order
  R-->>L: {:continue, state}

  Note over L: iteration 2 — model summarises results
```

**What to notice:**

- Both tools `parallel_safe?: true`, batched via [`Loop.Parallel.run/3`](../lib/ex_athena/loop/parallel.ex).
- Results re-assembled in the order the model issued them, regardless of completion order.
- `tool_calls_made` increments by 2.

---

## Trace 3 — Context overflow + reactive recovery

```mermaid
sequenceDiagram
  autonumber
  participant L as Loop
  participant R as ReAct
  participant P as Provider
  participant Cp as Compactor

  Note over L: iteration N — state.messages is large
  L->>L: maybe_compact (proactive — not triggered yet)
  L->>R: iterate(state)
  R->>P: query(Request)
  P-->>R: {:error, :context_too_long}
  R-->>L: {:error, :error_prompt_too_long}

  L->>L: handle_prompt_too_long
  L->>L: apply_auto_pin
  L->>Cp: run(state, estimate, force: true)
  Cp->>Cp: BudgetReduction — drop ui_payloads
  Cp->>Cp: Snip — drop interior messages
  Cp->>Cp: Microcompact / ContextCollapse
  Cp->>P: Summary stage — produce terse summary
  P-->>Cp: summary text
  Cp-->>L: {:compact, new_messages, %{before: 110000, after: 45000}}

  L->>R: iterate(state) — retry once
  R->>P: query(smaller Request)
  P-->>R: Response.text="..." + tool_calls=[]
  R-->>L: {:halt, state} with :stop
  L-->>caller: {:ok, %Result{finish_reason: :stop}}
```

**What to notice:**

- Mode returns the *typed* error so the kernel knows to attempt recovery (not just any error).
- `apply_auto_pin` protects paired tool_call/result messages from being orphaned by Summary.
- One-shot retry: if the second call also fails, terminates with `:error_prompt_too_long`.

---

## Trace 4 — Permission denial

```mermaid
sequenceDiagram
  autonumber
  participant L as Loop
  participant R as ReAct
  participant P as Provider
  participant Perm as Permissions
  participant H as Hooks
  participant Cb as can_use_tool callback

  L->>R: iterate(state) — phase: :default
  R->>P: query
  P-->>R: tool_calls=[Bash{command: "rm -rf /"}]
  R->>R: append assistant msg
  R->>Perm: check(tc, ctx, opts)
  Perm->>Perm: disallowed? no
  Perm->>Perm: allowed? n/a
  Perm->>Perm: phase :default — fall through
  Perm->>Cb: invoke can_use_tool("bash", %{"command" => "rm -rf /"}, ctx)
  Cb-->>Perm: {:deny, "won't run rm -rf"}
  Perm-->>R: {:deny, %Denial{code: :user_denied, reason: "won't run rm -rf"}}
  R->>H: PermissionDenied
  R->>H: ToolDenied
  R->>R: synth tool_result with is_error: true, content: "won't run rm -rf"
  R->>R: ++ consecutive_mistakes
  R-->>L: {:continue, state}

  Note over L,R: model sees the denial → tries another approach
  L->>R: iterate(state) — model now uses Grep instead of Bash
```

**What to notice:**

- The model **sees the denial** as a tool_result and can try a different tool. Denial is recoverable, not terminal.
- `consecutive_mistakes` increments. Three denials in a row → `:error_consecutive_mistakes`.
- `PermissionDenied` and `ToolDenied` hooks fire for logging — they can't reverse the decision.

---

## Trace 5 — Subagent spawn

```mermaid
sequenceDiagram
  autonumber
  participant Parent as Parent Loop
  participant R as ReAct
  participant Sp as Tools.SpawnAgent
  participant Def as Agents.Definition
  participant W as Agents.Worktree
  participant Sub as Subagent Loop
  participant H as Hooks
  participant Sc as Sidechain

  Parent->>R: iterate(state)
  R->>R: tool_calls=[SpawnAgent{name: "reviewer", prompt: "..."}]
  R->>Sp: execute(args, ctx)
  Sp->>Def: load(".exathena/agents/reviewer.md")
  Def-->>Sp: %Definition{tools: [read,grep,lsp], phase: :plan, isolation: :worktree, model: "claude-sonnet-4-6"}
  Sp->>H: SubagentStart {agent_name: "reviewer", parent_session_id: parent.sid}
  Sp->>W: create(parent.sid, "reviewer")
  W-->>Sp: ".exathena/worktrees/<sid>-reviewer"
  Sp->>Sub: Loop.run(prompt, ctx with cwd=worktree, parent_session_id=parent.sid, …)
  loop subagent iterations
    Sub->>Sub: read / grep / analyse
    Sub->>Sc: stream events to parent's sidechain
  end
  Sub-->>Sp: {:ok, %Result{text: "Critique: ..."}}
  Sp->>W: cleanup(path) — keep if changes, sweep if not
  Sp->>H: SubagentStop {result, parent_session_id}
  Sp-->>R: {:ok, "Critique: ...", %{kind: :subagent_result, payload: %{summary, full_session_id}}}
  R->>R: append tool_result with ui_payload
  R-->>Parent: {:continue, state}

  Note over Parent: parent continues with critique in context
```

**What to notice:**

- The parent's Mode doesn't see the subagent's internal turns — only the final tool_result (with `ui_payload` for rich UI).
- `SubagentStart` / `SubagentStop` hooks fire on the parent's hook table.
- Subagent transcript is queryable via the sidechain (`parent_session_id`) but doesn't bloat the parent's messages.
- Worktree is kept if the subagent produced changes; otherwise auto-cleaned.

---

## Trace 6 — Streaming host events (local provider, `on_event`)

What a host (web chat / TUI) actually receives over `on_event` for a three-iteration run on a local reasoning model (`provider: :exo, model: "mlx-community/Qwen3.6-27B"`). Left: loop activity; right: the exact event tuples, in order.

```text
ITERATION 0                                  → {:iteration, 0}
  model streams reasoning                    → {:thinking, "I need to see the README and check the port…"}
  response: text "" + 2 tool calls           → {:usage, %{input_tokens: 880, output_tokens: 61}}
    (no {:content, _} — empty text on a tool-call-only turn is never emitted)
  bash call (mutating → runs first, serial)  → {:tool_call, %ToolCall{id: "t2", name: "bash", …}}
    PreToolUse hook denies                   → {:tool_result, %ToolResult{tool_call_id: "t2",
                                                  content: "rm blocked", is_error: true}}
  read call (parallel-safe)                  → {:tool_call, %ToolCall{id: "t1", name: "read", …}}
    executes (host shows "running…"
    between these two events)                → {:tool_result, %ToolResult{tool_call_id: "t1",
                                                  content: "1  # Udin\n2  …", is_error: nil}}

ITERATION 1                                  → {:iteration, 1}
  model calls edit                           → {:thinking, "Now I add the note under Setup…"}
                                             → {:usage, %{input_tokens: 6_410, output_tokens: 88}}
                                             → {:tool_call, %ToolCall{id: "t3", name: "edit", …}}
                                             → {:tool_result, %{tool_call_id: "t3", content: "edited README.md"}}
  edit returned a UI split                   → {:tool_ui, %{tool_call_id: "t3", kind: :diff,
                                                  payload: %{path: "README.md", diff: "…"}}}

ITERATION 2                                  → {:iteration, 2}
  model streams the final answer             → {:content, "Added a PORT note "}
                                             → {:content, "to the README."}
                                             → {:usage, %{input_tokens: 6_920, output_tokens: 47}}
  no tool calls → :stop                      → {:done, %Result{finish_reason: :stop, iterations: 2,
                                                  tool_calls_made: 3, text: "Added a PORT note to the README.",
                                                  usage: %{input_tokens: 14_210, output_tokens: 196, …}}}
```

**What to notice:**

- `{:tool_call, _}` is emitted **before** gating/execution ([`react.ex` `run_single_tool_call`](../lib/ex_athena/modes/react.ex)) — hosts can show a spinner until the matching `{:tool_result, _}` arrives. Same timing as the Claude Code path, where the CLI announces the call before running it.
- Reasoning models narrate in the thinking channel: tool-call turns often have **no assistant text**, so no `{:content, _}` is emitted for them (an empty end-of-turn text is suppressed).
- The denial is just an `is_error: true` tool result — the model sees it next turn and pivots; `consecutive_mistakes` was reset by the successful `read` in the same turn.
- Streaming deltas suppress the end-of-turn full-text emission — hosts never see the same text twice.
- On the Claude Code provider the same vocabulary applies, plus `Result.session_id` carries the CLI session id; hosts pass it back as `resume:` so the next turn continues that conversation.

---

## Comparing the six traces

```mermaid
flowchart LR
  T1[1 · Single tool] --> simple[2 iterations<br/>no surprises]
  T2[2 · Parallel multi-tool] --> conc[1 iteration with concurrent tools<br/>parallel_safe? batched]
  T3[3 · Context overflow] --> rec[Reactive compaction<br/>1-shot retry]
  T4[4 · Permission denial] --> resilient[Denial is recoverable<br/>model pivots]
  T5[5 · Subagent] --> compose[Parent sees only summary<br/>subagent has own loop]
  T6[6 · Streaming events] --> host[Exact on_event sequence<br/>tool_call before execution]
```

Each trace exercises a different piece of the kernel's contract:

| Trace | Showcases |
|---|---|
| 1 | Basic happy path, `:stop` termination, hook ordering |
| 2 | Parallel-safe batching, multi-tool turn |
| 3 | Reactive recovery, auto-pin, compaction pipeline |
| 4 | Deny-first gate, recoverable error path, mistake counter |
| 5 | Composition, worktree isolation, sidechain transcripts |
| 6 | Host event vocabulary, tool-call/result timing, thinking-channel narration, resume |

---

## Where to go next

- [03 · Reasoning loop](03-reasoning-loop.md) — the decision tree that drives all six traces.
- [07 · Tools](07-tools.md) → [08 · Permissions](08-permissions.md) → [09 · Hooks](09-hooks.md) — the three layers traversed in every tool-execution segment.
- [17 · Error recovery](17-error-recovery.md) — when a trace ends in something other than `:stop`.
