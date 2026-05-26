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
          optional(:streaming) => boolean(),
          optional(:json_mode) => boolean(),
          optional(:structured_output) => boolean(),
          optional(:max_tokens) => pos_integer(),
          optional(:supports_resume) => boolean(),
          optional(:supports_system_prompt) => boolean(),
          optional(:supports_temperature) => boolean(),
          optional(:compact_tool_schemas) => boolean()
        }
end
