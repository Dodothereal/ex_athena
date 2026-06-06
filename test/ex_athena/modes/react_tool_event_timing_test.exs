defmodule ExAthena.Modes.ReactToolEventTimingTest do
  @moduledoc """
  Verifies host-visible tool event timing: `{:tool_call, _}` must reach the
  host BEFORE the tool executes (so UIs can show a "running…" state), and
  `{:tool_result, _}` after it finishes.

  This matches the Claude Code provider's semantics, where the tool-call
  event streams when the model requests the tool — keeping the two runner
  paths behaviourally identical for hosts.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  # Serial (non-parallel-safe) tool that announces its own execution, so the
  # test can order it against the emitted loop events.
  defmodule AnnouncingTool do
    @behaviour ExAthena.Tool
    def name, do: "announce"
    def description, do: "announce"
    def parallel_safe?, do: false
    def schema, do: %{type: "object", properties: %{}, required: []}

    def execute(_args, _ctx) do
      case Process.get(:timing_test_pid) do
        pid when is_pid(pid) -> send(pid, :tool_executing)
        _ -> :ok
      end

      {:ok, "done"}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "timing_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "{:tool_call} reaches the host before the tool executes", %{dir: dir} do
    test_pid = self()
    Process.put(:timing_test_pid, test_pid)
    on_event = fn event -> send(test_pid, {:event, event}) end

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "announce", arguments: %{}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "finished", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [AnnouncingTool],
               on_event: on_event
             )

    # assert_receive matches anywhere in the mailbox, so drain it and check
    # positions: the tool-call event must precede the tool's own execution
    # marker, and the result must follow it.
    messages = drain_mailbox([])

    call_idx = Enum.find_index(messages, &match?({:event, {:tool_call, %ToolCall{id: "t1"}}}, &1))
    exec_idx = Enum.find_index(messages, &(&1 == :tool_executing))

    result_idx =
      Enum.find_index(messages, &match?({:event, {:tool_result, %{tool_call_id: "t1"}}}, &1))

    assert call_idx, "no {:tool_call, _} event received"
    assert exec_idx, "tool never executed"
    assert result_idx, "no {:tool_result, _} event received"

    assert call_idx < exec_idx,
           "{:tool_call} must reach the host before the tool executes " <>
             "(got call at #{call_idx}, execution at #{exec_idx})"

    assert exec_idx < result_idx
  end

  defp drain_mailbox(acc) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a denied tool still emits {:tool_call} followed by an error {:tool_result}", %{dir: dir} do
    test_pid = self()
    on_event = fn event -> send(test_pid, {:event, event}) end

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "announce", arguments: %{}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "finished", finish_reason: :stop, provider: :mock}
      end
    end

    deny_hook = fn _input, _id -> {:deny, "not allowed"} end

    assert {:ok, %Result{}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [AnnouncingTool],
               hooks: %{PreToolUse: [%{hooks: [deny_hook]}]},
               on_event: on_event
             )

    assert_receive {:event, {:tool_call, %ToolCall{id: "t1"}}}
    assert_receive {:event, {:tool_result, %{tool_call_id: "t1", is_error: true}}}
  end
end
