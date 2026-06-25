# LSP-backed Elixir code intelligence (favoured over grep)

**Date:** 2026-06-25
**Status:** Approved

## Goal

Give the agent (orchestrate and other modes) AST-accurate Elixir code analysis
that is preferred over `grep` for navigating code — finding where a
module/function/type is defined or used, and outlining a file's structure.

## Decision: drop `rag_ex` and `ash_ai`

The original request named two libraries. Research disqualified both:

- **`ash_ai`** is hard-wired to the Ash framework — its tools expose Ash
  *actions* and its vectorization embeds Ash *record data*. It has no
  source-code analysis capability and cannot run unless the host is an Ash app.
  ex_athena is not an Ash app. Not a fit.
- **`rag_ex`** is an experimental single-author RAG fork (10 stars, git/hex
  version skew). Using it for code search would require standing up
  Postgres + pgvector (ex_athena has no DB today), a Gemini API key
  (embeddings are Gemini-only), non-optional `gemini_ex`/`triple_store` deps,
  plus our own Repo, `Chunk` schema, migrations, and indexer. It also does only
  generic/format-aware text chunking — no AST-aware code chunking.

ex_athena already runs a managed `elixir-ls` client (`ExAthena.Lsp.*`). LSP
gives AST-accurate symbol search, references, and definitions with **no new
infra** (no DB, no API key, no ML deps). That is the strongest "favoured over
grep" option for Elixir.

## What exists today

`ExAthena.Tools.Lsp` exposes four **position-based** actions: `definition`,
`references`, `hover`, `diagnostics`. The gap: every action needs a precise
`file` + 0-indexed `line`/`character`. There is **no way to find a symbol by
name** — which is exactly what grep is used for. The `Client` (`request/4`) is
method-agnostic, so new LSP methods need no transport change.

## Design

Extend the existing `lsp` tool (no new parallel tool) with two name-based
actions:

| Action | Args | LSP method | Replaces grep for |
|---|---|---|---|
| `workspace_symbol` | `query`, optional `language` (default `"elixir"`) | `workspace/symbol` | "where is module/function/type `X`" project-wide |
| `document_symbol` | `file` | `textDocument/documentSymbol` | a file's outline (modules/functions/callbacks) |

These compose with the existing actions: `workspace_symbol` finds a name → a
position; the model then calls `references`/`definition` precisely.

### Components

1. **`lib/ex_athena/tools/lsp.ex`**
   - Schema: add the two actions to the `action` enum; add `query` and
     `language` properties; refresh descriptions.
   - `execute/2`: branch — `workspace_symbol` resolves a client by *language*
     (`Manager.ensure_started/2`, default `:elixir`, validated against a
     fixed map; no file, no `didOpen`); all other actions keep the existing
     file-based flow (`client_for_file` + `didOpen` + dispatch), and
     `document_symbol` joins that flow.
   - Formatters: `workspace_symbol` → `N symbol(s):` + `name (kind) path:line:col`
     per `SymbolInformation`; `document_symbol` → `N symbol(s):` + indented
     `name (kind) :line:col`, recursing into hierarchical `DocumentSymbol`
     children (also tolerating flat `SymbolInformation`). Shared `kind_label/1`
     maps the 26 LSP `SymbolKind` values.
   - New errors: `:missing_query` (workspace_symbol without `query`),
     `:unsupported_language` (unknown `language`).

2. **`lib/ex_athena/lsp/client.ex`** — declare client capabilities for
   `workspace.symbol` and `textDocument.documentSymbol` in the `initialize`
   handshake (correctness; servers largely respond regardless).

3. **Wiring — make read-only workers able to use it and prefer it:**
   - `priv/agents/explore.md` and `priv/agents/plan.md`: add `lsp` to their
     `tools:` lists (today neither has it; `general`/`implementer` already do).
   - `priv/agents/explore.md` prompt: one line steering Elixir code lookups to
     `lsp` over `grep`.
   - `lib/ex_athena/modes/orchestrate.ex` `@worker_suffix`: one bullet — for
     Elixir, prefer `lsp` (`workspace_symbol`/`definition`/`references`) over
     `grep`.
   - Tool descriptions: strengthen `lsp`'s; add a pointer in `grep`'s. These
     travel with the tool into every mode automatically.

4. **Tests (TDD):**
   - `test/support/fake_lsp_server.exs`: deterministic handlers for
     `workspace/symbol` (returns `SymbolInformation[]`) and
     `textDocument/documentSymbol` (returns hierarchical `DocumentSymbol[]`),
     placed before the MethodNotFound catch-all; honour the existing
     `fail_next_request` flag.
   - `test/ex_athena/tools/lsp_test.exs`: success + shape assertions for both
     actions, `:missing_query`, and `:unsupported_language` for a bad
     `language`.

## Non-goals / caveats

- **Indexing readiness:** `workspace/symbol` on ElixirLS returns results only
  after the project is compiled/indexed. The current client does not wait on
  indexing (neither do today's actions); an early call may return few/empty
  results. Documented, not solved here (YAGNI; revisit if it bites).
- No new dependencies. No database. No embeddings.
- Other languages keep working (the registry already maps py/rs/go/ts); the
  `language` arg simply defaults to Elixir.
