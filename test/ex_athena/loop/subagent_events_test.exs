defmodule ExAthena.Loop.SubagentEventsTest do
  @moduledoc """
  Subagent boundary events must reach the host's `on_event` callback.

  SpawnAgent emits `{:subagent_spawn, …}` / `{:subagent_result, …}` via
  `ctx.assigns[:on_event]` — the loop is responsible for wiring the run's
  `on_event` into the tool context so those events aren't silently dropped.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "sub_ev_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "the host on_event receives subagent spawn and result events", %{dir: dir} do
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    parent_responder = fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "delegating",
            tool_calls: [
              %ToolCall{id: "c1", name: "spawn_agent", arguments: %{"prompt" => "sub task"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, _} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: parent_responder],
               tools: [ExAthena.Tools.SpawnAgent],
               cwd: dir,
               memory: false,
               on_event: fn ev -> send(test_pid, {:athena, ev}) end,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [
                     responder: fn _ ->
                       %Response{text: "sub finished", finish_reason: :stop, provider: :mock}
                     end
                   ],
                   tools: [],
                   memory: false
                 ]
               }
             )

    assert_receive {:athena, {:subagent_spawn, %{id: sub_id, prompt: "sub task"}}}
    assert_receive {:athena, {:subagent_result, %{id: ^sub_id, text: "sub finished"}}}
  end
end
