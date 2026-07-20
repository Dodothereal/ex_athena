# Tool calls

ExAthena supports two tool-calling protocols and falls back between them
automatically when a model misbehaves.

## Native tool calls

The OpenAI / Anthropic / Ollama native shape. Providers declaring
`native_tool_calls: true` in their capabilities use this by default.

### OpenAI / Ollama

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [
    {
      "id": "call_abc",
      "type": "function",
      "function": {
        "name": "read_file",
        "arguments": "{\"path\": \"/tmp/foo\"}"
      }
    }
  ]
}
```

### Anthropic Claude

```json
{
  "role": "assistant",
  "content": [
    {
      "type": "tool_use",
      "id": "toolu_abc",
      "name": "read_file",
      "input": {"path": "/tmp/foo"}
    }
  ]
}
```

`ExAthena.ToolCalls.Native.parse/1` handles both shapes and returns
canonical `%ExAthena.Messages.ToolCall{}` structs.

## Text-tagged tool calls

For models without native tool-call support, ExAthena supports a
prompt-engineered protocol:

````
~~~tool_call
{"name": "read_file", "arguments": {"path": "/tmp/foo"}}
~~~
````

Rules:

- One block per call; multiple blocks in a single response are allowed.
- Both fences must be on their own lines.
- `id` is optional; missing ids are generated server-side.
- Malformed JSON in a block returns an error.

`ExAthena.ToolCalls.augment_system_prompt/2` appends instructions for
this protocol to the system prompt, along with each tool's schema:

```elixir
ExAthena.ToolCalls.augment_system_prompt(
  "Be helpful.",
  [
    %{name: "read_file", description: "read a file", schema: %{type: "object", properties: %{path: %{type: "string"}}}}
  ]
)
```

## Auto-fallback

`ExAthena.ToolCalls.extract/2` picks the protocol based on provider
capabilities AND the response shape:

| Provider says | Response has | Parser used |
|---|---|---|
| `native: true` | `tool_calls` array | Native |
| `native: true` | empty `tool_calls`, text contains `~~~tool_call` | TextTagged (fallback) |
| `native: true` | empty, no fences | returns `{:ok, []}` |
| `native: false` | any | TextTagged |

`ExAthena.Loop` uses this to recover when a provider declares
native support but the model actually emits text-tagged blocks — common
with smaller Ollama models.

## Arguments

Both parsers accept:

- A decoded map (most common from Claude's `input`).
- A JSON-encoded string (OpenAI's `arguments`).
- An empty string (treated as `{}`).

Anything else returns an error. Never trust arbitrary tool-call payloads
without schema validation at the tool-execution layer.
