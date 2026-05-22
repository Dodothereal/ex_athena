# 16 · Structured Output — Schema-Validated Extraction

> **What this answers:** how does `ExAthena.extract_structured/2` guarantee a validated map? What's the repair loop?
> **Audience:** consumers extracting structured data; contributors maintaining the repair logic.

---

## The pipeline

```mermaid
flowchart TD
  start([extract_structured prompt schema]) --> req[Build Request with response_format json_schema]
  req --> call[Provider.query]
  call --> resp[Response.text]
  resp --> parse{parse as JSON}
  parse -- :ok, data --> val{validate against schema}
  parse -- :error --> rep1[Repair attempt 1]
  val -- valid --> ok([ok validated map])
  val -- invalid --> rep2[Repair attempt 2]

  rep1 --> repPrompt[Inject error message + reformat prompt]
  rep2 --> repPrompt
  repPrompt --> retry{retry budget left?}
  retry -- yes --> call
  retry -- no --> termRetries[set finish_reason :error_max_structured_output_retries]
  termRetries --> err([error :error_max_structured_output_retries])

  parse -- syntactically broken across all retries --> termSchema[set :error_schema_validation]
  termSchema --> err
```

Sources:
- Entry: [`ExAthena.Structured.extract/2`](../lib/ex_athena/structured.ex), exposed as [`ExAthena.extract_structured/2`](../lib/ex_athena.ex#L118).
- Validator + repair: [`ExAthena.StructuredOutput`](../lib/ex_athena/structured_output.ex).

---

## Usage

```elixir
schema = %{
  type: "object",
  properties: %{
    severity: %{type: "string", enum: ["low", "medium", "high"]},
    file: %{type: "string"},
    line: %{type: "integer", minimum: 1},
    summary: %{type: "string"}
  },
  required: ["severity", "file", "line", "summary"]
}

{:ok, data} =
  ExAthena.extract_structured("Classify this error: ...",
    schema: schema,
    provider: :claude,
    max_repairs: 2
  )

#=> %{"severity" => "medium", "file" => "lib/foo.ex", "line" => 42, "summary" => "..."}
```

### Options

- `:schema` — JSON Schema map. Required.
- `:max_repairs` — repair budget. Default 2.
- All other `Loop.run/2` options (`:provider`, `:model`, `:system_prompt`, `:messages`, …).

When the response format is supported natively by the provider (capabilities `supports_response_format_json_schema: true`), the schema is also passed in the request's `response_format` — many providers will then refuse to emit invalid JSON, eliminating most repair cycles.

---

## Repair loop

When validation fails, the runtime injects a synthesised user message describing exactly *what* failed and what the schema requires:

```text
Your previous response could not be parsed as the required JSON schema:

  - $.line: expected integer, got string

Reformat your response strictly as valid JSON matching:

  { "type": "object", "properties": {…}, "required": [...] }

Respond with the JSON only — no commentary, no markdown fences.
```

Then re-invokes the provider with the same conversation + this remediation. After `:max_repairs` failed attempts, the call terminates with `:error_max_structured_output_retries` (category `:capacity`) — the diagnostic is attached to `error_diagnostic` on the Result.

---

## When to use which termination

| Scenario | Finish reason | Category | Caller action |
|---|---|---|---|
| Valid response on first try | `:stop` | `:success` | Read `Result.text` or extracted map |
| Repair budget exhausted, last error was a schema mismatch | `:error_max_structured_output_retries` | `:capacity` | Increase `:max_repairs` *or* simplify the schema *or* swap to a stronger model |
| Response wasn't even parseable JSON across all retries | `:error_schema_validation` | `:retryable` | Caller may retry once with a stricter system prompt; if it keeps failing, the model is the wrong choice |
| Provider returned 401/403 | `:error_provider_auth` | `:fatal` | Fix credentials |

The repair loop sits *inside* a single `Loop.run`. Iterations consumed by repair count against `:max_iterations`, but the dedicated `:max_repairs` budget exists so callers can tune extraction tolerance without giving the rest of the loop more rope.

---

## Contributor notes

- **Schema is JSON Schema, not Ash**: today we accept plain maps. A future stage could derive these from `Ash.Resource` schemas — but the core extraction is provider-agnostic and decoupled from any data layer.
- **`response_format` first, validator second**: when the provider supports the schema natively, *prefer that*. The internal validator is a fallback for providers that don't enforce schemas server-side.
- **`error_diagnostic` is structured**: carries `path`, `expected`, `got`, `raw_response`. Surface it to callers verbatim — don't stringify into `halted_reason`.
- **Don't loop forever**: `max_repairs` defaults to 2 on purpose. The empirical observation is that if a model can't conform in 3 tries, it won't. Bumping to 5 wastes tokens.
- **Per-call cost**: each repair is one provider call. Track via Result.cost_usd, not the repair count.

---

## Where to go next

- [05 · State & termination](05-state-and-termination.md) — `:error_max_structured_output_retries` and `:error_schema_validation`.
- [17 · Error recovery](17-error-recovery.md) — what to do on each finish reason.
- [10 · Providers](10-providers.md) — capability `supports_response_format_json_schema`.
