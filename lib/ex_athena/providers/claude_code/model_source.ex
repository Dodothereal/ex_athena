defmodule ExAthena.Providers.ClaudeCode.ModelSource do
  @moduledoc """
  Boundary for discovering the models the local Claude Code CLI supports.

  The `claude_code` SDK reports its available models through the control-protocol
  initialize handshake (`ClaudeCode.Session.supported_models/1`). That requires a
  live CLI session, so we wrap it behind this behaviour: the real implementation
  ([`SDKModelSource`](`ExAthena.Providers.ClaudeCode.SDKModelSource`)) talks to the
  SDK, while tests supply a stub. Pick the implementation via app config
  (`:ex_athena, :claude_code_model_source`).
  """

  @doc """
  Returns the models the CLI reports, as `ClaudeCode.Model.Info` structs (or
  plain maps with a `:value`/`"value"` key). `{:error, reason}` when the CLI is
  unavailable or the handshake fails.
  """
  @callback supported_models() :: {:ok, [struct() | map()]} | {:error, term()}
end
