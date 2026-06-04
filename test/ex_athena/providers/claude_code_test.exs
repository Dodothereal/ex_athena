defmodule ExAthena.Providers.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias ExAthena.Providers.ClaudeCode

  test "is registered as the :claude_code provider" do
    assert ExAthena.Config.provider_module(:claude_code) == ClaudeCode
  end

  test "declares self-contained-agent capabilities" do
    caps = ClaudeCode.capabilities()

    # The CLI runs its own tools, so ex_athena must not execute tools for it.
    refute caps.native_tool_calls
    assert caps.streaming
    assert caps.supports_resume
    # claude_code exposes no temperature knob.
    refute caps.supports_temperature
  end

  test "capabilities/1 falls back to the static map" do
    assert ClaudeCode.capabilities(model: "opus") == ClaudeCode.capabilities()
  end

  # The model list is sourced from the claude_code SDK's `supported_models`
  # handshake. We wrap that boundary behind a ModelSource behaviour we own so it
  # can be stubbed here without standing up the real CLI.
  defmodule UnsortedSource do
    @behaviour ExAthena.Providers.ClaudeCode.ModelSource
    @impl true
    def supported_models do
      {:ok,
       [
         %{value: "claude-sonnet-4-6", display_name: "Sonnet 4.6"},
         %{value: "claude-opus-4-8", display_name: "Opus 4.8"},
         # blank values are dropped
         %{value: ""},
         %{value: nil},
         # duplicates are collapsed
         %{value: "claude-opus-4-8", display_name: "Opus 4.8"}
       ]}
    end
  end

  defmodule ErrorSource do
    @behaviour ExAthena.Providers.ClaudeCode.ModelSource
    @impl true
    def supported_models, do: {:error, :unavailable}
  end

  test "list_models/1 returns sorted, unique, non-blank model values from the source" do
    assert ClaudeCode.list_models(UnsortedSource) ==
             {:ok, ["claude-opus-4-8", "claude-sonnet-4-6"]}
  end

  test "list_models/1 propagates source errors" do
    assert ClaudeCode.list_models(ErrorSource) == {:error, :unavailable}
  end
end
