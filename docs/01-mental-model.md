# 01 · Mental Model

> **What this answers:** the one-page picture of how `ExAthena.run(prompt, …)` becomes an answer.
> **Audience:** consumer-first; contributors should still skim before reading [02 · Architecture](02-architecture.md).

---

## The whole story in one diagram

```mermaid
flowchart TD
  start([ExAthena.run prompt opts]) --> build[Build initial Loop.State]
  build --> sStart[(Fire SessionStart hook)]
  sStart --> ups[(Fire UserPromptSubmit hook)]
  ups --> caps{Caps OK?<br/>iter · mistakes · budget · no_progress}
  caps -- no --> term1[Set finish_reason<br/>error_max_turns / error_no_progress / etc.]
  caps -- yes --> compact{Need compaction?}
  compact -- yes --> doCompact[Run compactor pipeline]
  doCompact --> mode
  compact -- no --> mode[Mode.iterate state]

  mode --> chat[Provider.query or stream]
  chat --> parse[Extract tool calls<br/>native · TextTagged · RawJson]
  parse --> hasCalls{Tool calls?}

  hasCalls -- no --> stop[Append assistant text<br/>set finish_reason :stop]
  stop --> result

  hasCalls -- yes --> perm{Permissions.check<br/>disallow → allow → phase → callback}
  perm -- deny --> denyMsg[Append tool_result :deny<br/>increment consecutive_mistakes]
  denyMsg --> caps
  perm -- allow --> pre[(Fire PreToolUse hook)]
  pre -- deny / halt --> denyMsg
  pre -- ok --> exec[Tool.execute args ctx<br/>parallel-safe batched]
  exec --> post[(Fire PostToolUse hook<br/>augment / halt)]
  post --> appendResult[Append tool_result message]
  appendResult --> caps

  term1 --> result
  result([Build ExAthena.Result<br/>fire Stop / StopFailure + SessionEnd])

  classDef hook fill:#fef3c7,stroke:#92400e;
  classDef terminal fill:#fecaca,stroke:#991b1b;
  classDef kernel fill:#fde68a,stroke:#92400e;
  class sStart,ups,pre,post hook
  class stop,term1 terminal
  class caps,compact,mode kernel
```

That's it. A turn is: **check caps → maybe compact → run mode → maybe execute tools → loop.** Termination is *always* a typed `finish_reason`.

---

## The three layers

```mermaid
flowchart TD
  subgraph K [Kernel — caps · budget · counters · termination]
    Loop[ExAthena.Loop]
    State[Loop.State]
    Term[Loop.Terminations<br/>12 finish reasons]
  end

  subgraph S [Strategy — per-turn control flow]
    ReAct[Modes.ReAct]
    PaS[Modes.PlanAndSolve]
    Refl[Modes.Reflexion]
  end

  subgraph D [Drivers — talk to the world]
    Prov[Provider · req_llm]
    Tools[Tools]
    Perm[Permissions]
    Hooks[Hooks]
    Comp[Compactor]
  end

  Loop --> S
  S --> D
  Loop --> State
  Loop --> Term
```

| Layer | Pace of change | Owned by |
|---|---|---|
| **Drivers** | Changes constantly — new providers, new tools, new hooks. | Library + consumer extensions |
| **Strategy** | Stable — three modes today; you add a custom one occasionally. | Library + rare custom modes |
| **Kernel** | Very stable — the contract every Mode and Driver depends on. | Library only |

---

## What ExAthena *is* and *is not*

> "**1.6% reasoning, 98.4% harness.**" The model does the thinking; ExAthena does everything else.

ExAthena is **operational scaffolding** around an LLM:

- ✅ Iteration limits, budget tracking, no-progress detection.
- ✅ Typed termination subtypes for retry classification.
- ✅ Tool dispatch with parallel-safe batching.
- ✅ Deny-first permission gating with 5 phases.
- ✅ 18 lifecycle hook events for intercept / inject / transform.
- ✅ Five-stage compaction pipeline + reactive recovery.
- ✅ Provider-agnostic API across Ollama / OpenAI / Claude / Gemini / llamacpp.
- ✅ Session persistence with resume, rewind, sidechain transcripts.
- ✅ Composable subagents with optional worktree isolation.

ExAthena is **not**:

- ❌ A model. It calls one. You bring the LLM.
- ❌ A vector store. Memory is file-based (`AGENTS.md`/`CLAUDE.md`/`SKILL.md`).
- ❌ A runtime. It runs *inside* your BEAM app.

---

## Where to go next

- **See it play out** → [18 · End-to-end traces](18-end-to-end-traces.md)
- **See the subsystem map** → [02 · Architecture](02-architecture.md)
- **See the kernel mechanics** → [03 · Reasoning loop](03-reasoning-loop.md)
