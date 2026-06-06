defmodule ExAthena.Loop.ParallelTimeoutTest do
  @moduledoc """
  A concurrent tool call that exceeds tool_timeout_ms must surface as an
  error tool result — `Task.async_stream(on_timeout: :kill_task)` yields
  `{:exit, :timeout}` (a bare atom, not the `{reason, stack}` crash shape),
  which used to crash the whole run with a FunctionClauseError.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  defmodule SlowTool do
    @behaviour ExAthena.Tool
    def name, do: "slow"
    def description, do: "sleeps"
    def parallel_safe?, do: true
    def schema, do: %{type: "object", properties: %{}, required: []}

    def execute(_args, _ctx) do
      receive do
        :never -> :ok
      end
    end
  end

  test "a timed-out concurrent tool becomes an error result, not a run crash" do
    dir = Path.join(System.tmp_dir!(), "pt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "slow", arguments: %{}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "recovered", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [SlowTool],
               tool_timeout_ms: 50
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    assert tr.is_error
    assert tr.content =~ "timed out"
  end
end
