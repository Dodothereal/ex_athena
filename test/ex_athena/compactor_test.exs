defmodule ExAthena.CompactorTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactor
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  describe "estimate_tokens/2 (system prompt)" do
    test "adds the system prompt's token cost on top of the messages" do
      msgs = [%Message{role: :user, content: "hi"}]
      # A large system prompt — tool descriptions / skill catalogs routinely
      # run to thousands of tokens and are part of every request, yet were
      # previously excluded from the proactive estimate.
      prompt = String.duplicate("x", 4000)

      assert Compactor.estimate_tokens(msgs, prompt) ==
               Compactor.estimate_tokens(msgs) + div(4000, 4)
    end

    test "a nil system prompt is equivalent to estimate_tokens/1" do
      msgs = [%Message{role: :user, content: "hi"}]
      assert Compactor.estimate_tokens(msgs, nil) == Compactor.estimate_tokens(msgs)
    end
  end

  describe "estimate_tokens/1" do
    test "counts text content at ~4 chars per token + 8 fixed overhead" do
      msg = %Message{role: :user, content: String.duplicate("x", 4000)}
      assert Compactor.estimate_tokens([msg]) == div(4000, 4) + 8
    end

    test "counts an assistant tool_calls message by JSON envelope size" do
      msg = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [%ToolCall{id: "1", name: "bash", arguments: %{"cmd" => "ls"}}]
      }

      # 64 envelope + arguments JSON / 4
      args_json = byte_size(Jason.encode!(%{"cmd" => "ls"}))
      assert Compactor.estimate_tokens([msg]) == 64 + div(args_json, 4)
    end

    test "counts a tool_result message's payload (not a fixed 16-token blob)" do
      # A multi-KB tool result — e.g. a long bash output or a big file read.
      big_payload = String.duplicate("a", 40_000)

      msg = %Message{
        role: :tool,
        content: nil,
        tool_results: [%ToolResult{tool_call_id: "1", content: big_payload, is_error: false}]
      }

      tokens = Compactor.estimate_tokens([msg])
      # Must reflect the real payload size, not collapse to ~16. Allow a
      # generous floor so a future heuristic refinement doesn't break this
      # test, but the failure observed in production was tokens == 16.
      assert tokens >= div(40_000, 4),
             "tool_result payload should count toward the estimate; got #{tokens}"
    end

    test "sums multiple tool_results in a single message" do
      msg = %Message{
        role: :tool,
        content: nil,
        tool_results: [
          %ToolResult{tool_call_id: "1", content: String.duplicate("a", 4000), is_error: false},
          %ToolResult{tool_call_id: "2", content: String.duplicate("b", 4000), is_error: false}
        ]
      }

      assert Compactor.estimate_tokens([msg]) >= div(8000, 4)
    end

    test "tool_result with nil content stays cheap (no crash)" do
      msg = %Message{
        role: :tool,
        content: nil,
        tool_results: [%ToolResult{tool_call_id: "1", content: nil, is_error: true}]
      }

      tokens = Compactor.estimate_tokens([msg])
      assert is_integer(tokens) and tokens >= 0
    end

    test "regression: a conversation dominated by tool_results no longer reads as ~16 tokens each" do
      # Reproduces the production bug: 30 tool messages each holding ~3KB of
      # bash output were collectively counted as ~480 tokens (16 * 30), so
      # compaction never fired even though the real prompt was ~22.5K tokens.
      msgs =
        for i <- 1..30 do
          %Message{
            role: :tool,
            content: nil,
            tool_results: [
              %ToolResult{
                tool_call_id: "tc_#{i}",
                content: String.duplicate("x", 3_000),
                is_error: false
              }
            ]
          }
        end

      tokens = Compactor.estimate_tokens(msgs)
      # 30 messages × 3000 bytes / 4 chars-per-token = ~22_500. Pre-fix this
      # returned ~480. Assert we're at least in the right order of magnitude.
      assert tokens >= 15_000, "expected ~22.5K tokens, got #{tokens}"
    end
  end
end
