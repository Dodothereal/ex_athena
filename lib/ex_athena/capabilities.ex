defmodule ExAthena.Capabilities do
  @moduledoc """
  Provider-capability map shape.

  Each provider declares what it can do so the agent loop (shipping in Phase 2)
  can choose the right tool-call protocol and fall back gracefully when a
  provider lies about its capabilities.

  All keys are optional; missing keys are treated as `false` / `nil`.
  """

  @type t :: %{
          optional(:native_tool_calls) => boolean(),
          # Provider is a self-contained agent (e.g. the Claude Code CLI):
          # it runs its own tools and owns the reasoning loop. When true, the
          # loop skips text-tagged prompt augmentation and never parses/executes
          # tool calls from the response — the turn is terminal and the text is
          # the final answer.
          optional(:self_contained_tools) => boolean(),
          optional(:streaming) => boolean(),
          # Provider implements the optional `embed/2` callback, so
          # `ExAthena.embed/2` works against it. Callers feature-detect with
          # `ExAthena.capabilities(provider)[:embeddings]` before building a
          # retrieval layer on top.
          optional(:embeddings) => boolean(),
          # Provider can enumerate the models it serves (via `list_models/1` or
          # `list_models/0`), so `ExAthena.list_models/2` returns a real list.
          # Hosts feature-detect to choose between a model picker and a
          # free-text model field.
          optional(:model_listing) => boolean(),
          optional(:json_mode) => boolean(),
          optional(:structured_output) => boolean(),
          optional(:max_tokens) => pos_integer(),
          optional(:supports_resume) => boolean(),
          optional(:supports_system_prompt) => boolean(),
          optional(:supports_temperature) => boolean(),
          optional(:compact_tool_schemas) => boolean()
        }
end
