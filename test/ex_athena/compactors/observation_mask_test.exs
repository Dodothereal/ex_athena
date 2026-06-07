defmodule ExAthena.Compactors.ObservationMaskTest do
  @moduledoc """
  Observation masking (JetBrains/Anthropic pattern): old tool results
  become restorable placeholders; the tail, errors, and state-bearing
  tools survive; pairing (tool_call_id) is never broken.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.ObservationMask
  alias ExAthena.Loop.State
  alias ExAthena.Messages
  alias ExAthena.Messages.ToolCall

  defp turn(n, name, content, opts \\ []) do
    id = "c#{n}"
    args = Keyword.get(opts, :args, %{"path" => "file_#{n}.txt"})
    is_error = Keyword.get(opts, :is_error)

    [
      Messages.assistant("", [%ToolCall{id: id, name: name, arguments: args}]),
      Messages.tool_result(id, content, is_error)
    ]
  end

  defp state_with(messages), do: %State{messages: messages, meta: %{}}

  defp big, do: String.duplicate("x", 4_000)

  test "masks old results, keeps the last 5 tool results, preserves pairing" do
    messages =
      [Messages.user("go")] ++ Enum.flat_map(1..10, fn n -> turn(n, "read", big()) end)

    assert {:ok, %State{messages: masked}, _est} =
             ObservationMask.compact_stage(state_with(messages), %{
               tokens: 50_000,
               max_tokens: 64_000
             })

    tool_msgs = Enum.filter(masked, &(&1.role == :tool))
    assert length(tool_msgs) == 10

    {old, recent} = Enum.split(tool_msgs, 5)

    for msg <- old do
      [tr] = msg.tool_results
      assert tr.content =~ "output cleared"
      # Restorable: tool name + the path hint survive.
      assert tr.content =~ "read"
      assert tr.content =~ "file_"
      assert is_binary(tr.tool_call_id)
    end

    for msg <- recent do
      [tr] = msg.tool_results
      assert tr.content == big()
    end
  end

  test "never masks errors or todo_write results" do
    messages =
      [Messages.user("go")] ++
        turn(1, "bash", big(), is_error: true) ++
        turn(2, "todo_write", big(), args: %{}) ++
        Enum.flat_map(3..12, fn n -> turn(n, "read", big()) end)

    assert {:ok, %State{messages: masked}, _} =
             ObservationMask.compact_stage(state_with(messages), %{
               tokens: 50_000,
               max_tokens: 64_000
             })

    [err, todo | _] = Enum.filter(masked, &(&1.role == :tool))
    assert hd(err.tool_results).content == big()
    assert hd(todo.tool_results).content == big()
  end

  test "skips when the reclaim is too small to be worth a cache break" do
    messages = [Messages.user("go")] ++ Enum.flat_map(1..10, fn n -> turn(n, "read", "tiny") end)

    assert :skip =
             ObservationMask.compact_stage(state_with(messages), %{
               tokens: 1_000,
               max_tokens: 64_000
             })
  end

  test "idempotent: already-masked results are not re-counted or re-masked" do
    messages = [Messages.user("go")] ++ Enum.flat_map(1..10, fn n -> turn(n, "read", big()) end)

    {:ok, %State{messages: once}, _} =
      ObservationMask.compact_stage(state_with(messages), %{tokens: 0, max_tokens: 0})

    assert :skip =
             ObservationMask.compact_stage(state_with(once), %{tokens: 0, max_tokens: 0})
  end
end
