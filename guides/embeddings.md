# Embeddings

`ExAthena.embed/2` turns text into vectors through the same provider,
configuration and request-queue plumbing as `ExAthena.query/2`. It exists so
retrieval features (pgvector search, grounded code Q&A, dedup) can use the same
LLM seam as inference instead of scattering one-off HTTP calls across host
apps — one place to configure a base URL, one place to swap providers, one
place that respects the local-inference concurrency cap.

```elixir
{:ok, embedding} = ExAthena.embed("def handle_call(msg, _from, state)", provider: :ollama)

embedding.embeddings
#=> [[0.0123, -0.0456, …]]
```

## Always a list of vectors

`:embeddings` is a list of vectors, one per input, in input order — even for a
single string. Indexing jobs zip the result back onto their chunks, so a shape
that changed with the arity of the input would force every caller to branch.

## Batch in one round-trip

Pass a list to embed a whole batch in a single provider request. This matters:
an indexing run embeds hundreds of chunks, and a request per chunk would
dominate its runtime.

```elixir
chunks = Enum.map(functions, &render_chunk/1)

{:ok, %ExAthena.Embedding{embeddings: vectors, usage: usage}} =
  ExAthena.embed(chunks, provider: :ollama)

rows = Enum.zip(chunks, vectors)
```

Local servers serve very few concurrent requests, so `embed/2` acquires a
request-queue slot like every other provider call (see `ExAthena.RequestQueue`).
Batch, don't fan out.

## Configuring the model

Embedding models are a different population from chat models, so they get their
own config key. The provider's chat `model:` is deliberately **never** used as
a fallback — embedding with a chat model produces vectors that look fine and
retrieve badly.

```elixir
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "qwen3-coder",
  embedding_model: "nomic-embed-text"
```

Resolution order, per call: `model:` → `embedding_model:` → the provider's
`embedding_model:` config → the top-level `config :ex_athena, embedding_model:`.
With none of them set, `embed/2` returns a `:bad_request` error rather than
guessing.

`nomic-embed-text` is the recommended local default: its 8192-token context fits
function- and module-sized code chunks, where `mxbai-embed-large` truncates at
512.

```bash
ollama pull nomic-embed-text
```

## Feature detection

Embeddings are an optional provider capability. Check before you build a
retrieval layer on a provider that cannot embed:

```elixir
if ExAthena.capabilities(:ollama)[:embeddings] do
  ExAthena.embed(chunks, provider: :ollama)
end
```

Providers without the callback (e.g. `:claude_code`, which is a self-contained
agent CLI, not an inference endpoint) return
`{:error, %ExAthena.Error{kind: :capability}}`.

## How it routes

`req_llm` already exposes an embeddings API, so the `ExAthena.Providers.ReqLLM`
adapter rides it (`POST <base_url>/embeddings`) instead of speaking Ollama's
native `/api/embed`. Every OpenAI-wire-compatible backend is therefore covered
by one code path with the chat adapter's existing base-URL and API-key handling:

| Provider | Endpoint | Typical model |
|---|---|---|
| `:ollama` | `http://localhost:11434/v1/embeddings` | `nomic-embed-text` |
| `:openai` | `https://api.openai.com/v1/embeddings` | `text-embedding-3-small` |
| `:gemini` | Google's embeddings endpoint | `gemini-embedding-001` |
| `:openrouter`, JSON-file providers | the spec's `base_url` + `/embeddings` | provider-specific |

One wrinkle worth knowing: `req_llm` refuses to embed with a model it cannot
prove supports embeddings, and no local model is in its catalog
(`nomic-embed-text` doesn't even contain the literal string "embedding"). The
adapter therefore declares the capability inline on the model spec — the caller
asked for this model, and only the server can truthfully answer whether it can
embed. A model that cannot returns the server's own error.

## Testing

The Mock provider implements `embed/2`, so host apps stub embeddings without a
server:

```elixir
ExAthena.embed(["a", "b"],
  provider: :mock,
  model: "nomic-embed-text",
  mock: [embeddings: [[0.1, 0.2], [0.3, 0.4]]]
)
```

For input-dependent vectors — e.g. asserting that each chunk was embedded — pass
a responder, which receives the inputs as a list:

```elixir
mock: [embed_responder: fn texts -> Enum.map(texts, &fake_vector/1) end]
```

`mock: [error: :boom]` scripts a failure.
