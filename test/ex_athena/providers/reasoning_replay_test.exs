defmodule ExAthena.Providers.ReasoningReplayTest do
  @moduledoc """
  Rolling-checkpoint reasoning replay (June-2026 consensus: Qwen3+ template
  behavior, MiniMax/Kimi/DeepSeek guidance): reasoning is replayed for
  assistant messages WITHIN the current tool loop (after the last user
  message) and dropped for completed turns. req_llm's OpenAI encoder drops
  :thinking parts outbound, so replay uses inline <think> re-injection in
  the assistant content (the deepseek-legacy / MiniMax inline convention).
  """
  use ExUnit.Case, async: true

  alias ExAthena.Messages
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Providers.ReqLLM, as: Provider

  test "assistant/3 carries reasoning on the message" do
    msg = Messages.assistant("ok", nil, "because reasons")
    assert msg.reasoning == "because reasons"
  end

  test "reasoning replays ONLY for the LAST assistant message" do
    old_call = %ToolCall{id: "a", name: "read", arguments: %{}}
    mid_call = %ToolCall{id: "b", name: "read", arguments: %{}}
    cur_call = %ToolCall{id: "c", name: "read", arguments: %{}}

    # Agent loops have ONE user message — an "after the last user message"
    # window would replay EVERY turn's reasoning forever (unbounded
    # context growth, observed live). The window is exactly one turn: the
    # immediately preceding assistant message.
    messages = [
      Messages.user("the task"),
      Messages.assistant("looking", [old_call], "OLD reasoning"),
      Messages.tool_result("a", "x"),
      Messages.assistant("digging", [mid_call], "MID reasoning"),
      Messages.tool_result("b", "y"),
      Messages.assistant("acting", [cur_call], "CURRENT reasoning"),
      Messages.tool_result("c", "z")
    ]

    replayed = Provider.apply_rolling_reasoning(messages)

    [_, old_a, _, mid_a, _, cur_a, _] = replayed

    refute old_a.content =~ "OLD reasoning"
    refute mid_a.content =~ "MID reasoning"
    assert cur_a.content =~ "<think>"
    assert cur_a.content =~ "CURRENT reasoning"
    assert cur_a.content =~ "acting"
  end

  test "messages without reasoning pass through unchanged" do
    messages = [
      Messages.user("task"),
      Messages.assistant("plain answer")
    ]

    assert Provider.apply_rolling_reasoning(messages) == messages
  end

  test "the agent loop persists response thinking onto the assistant message" do
    dir = Path.join(System.tmp_dir!(), "rr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "f.txt"), "x")

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %ExAthena.Response{
            text: "checking",
            thinking: "I should read the file first",
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %ExAthena.Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, result} =
             ExAthena.Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    tool_call_msg =
      Enum.find(result.messages, fn m ->
        m.role == :assistant and is_list(m.tool_calls) and m.tool_calls != []
      end)

    assert tool_call_msg.reasoning == "I should read the file first"
  end
end
