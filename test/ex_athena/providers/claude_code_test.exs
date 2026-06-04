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
end
