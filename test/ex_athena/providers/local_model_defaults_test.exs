defmodule ExAthena.Providers.LocalModelDefaultsTest do
  @moduledoc """
  June-2026 audit fixes for small local models: sampling defaults (Qwen's
  official thinking/coding profile, never greedy/server-hot), a per-turn
  completion cap, context-overflow sniffing (local servers return 400+body,
  never a clean 413), and leaked-<think> normalization.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Providers.ReqLLM, as: Provider

  describe "context_overflow?/1" do
    test "detects OpenAI-compat overflow message bodies" do
      assert Provider.context_overflow?(%{
               status: 400,
               body: "This model's maximum context length is 262144 tokens"
             })

      assert Provider.context_overflow?({:error, "prompt is too long: 280000 tokens"})
      assert Provider.context_overflow?(%{status: 500, body: "context window exceeded"})
    end

    test "does not flag unrelated errors" do
      refute Provider.context_overflow?(%{status: 500, body: "internal server error"})
      refute Provider.context_overflow?(:timeout)
    end
  end

  describe "split_leaked_thinking/1" do
    test "routes complete <think> blocks out of the text" do
      {text, thinking} =
        Provider.split_leaked_thinking("<think>\nplan the read\n</think>\n\nHere's the answer.")

      assert text == "Here's the answer."
      assert thinking == "plan the read"
    end

    test "handles the orphan closing tag (template stripped the opener)" do
      {text, thinking} = Provider.split_leaked_thinking("step one reasoning\n</think>\n\nAnswer.")

      assert text == "Answer."
      assert thinking == "step one reasoning"
    end

    test "plain text passes through" do
      assert {"hello", nil} = Provider.split_leaked_thinking("hello")
    end
  end
end
