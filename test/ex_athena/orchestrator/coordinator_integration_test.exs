defmodule ExAthena.Orchestrator.CoordinatorIntegrationTest do
  @moduledoc """
  End-to-end: a Loop run wired with `coordinator:` populates the blackboard —
  main agent progress, runtime todo ledger, and subagent attribution via the
  SpawnAgent event sink.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Orchestrator.Coordinator

  setup do
    dir = Path.join(System.tmp_dir!(), "coord_int_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      Enum.at(responses, :counters.get(counter, 1) - 1) || List.last(responses)
    end
  end

  test "a run with coordinator: populates main progress, todos, and conclusions", %{dir: dir} do
    sid = "int-#{System.unique_integer([:positive])}"
    {:ok, coord} = Coordinator.start_for(sid)

    responses = [
      %Response{
        text: "Planning.\nCONCLUSION: starting with a todo list.",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "todo_write",
            arguments: %{
              "todos" => [
                %{"content" => "read the file", "status" => "in_progress"},
                %{"content" => "summarize", "status" => "pending"}
              ]
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "Done.\n\nCONCLUSION: everything works.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    assert {:ok, _} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.TodoWrite],
               coordinator: coord
             )

    {:ok, snap} = Coordinator.snapshot(sid)
    assert snap.main.status == :done
    assert [%{content: "read the file"}, %{content: "summarize"}] = snap.main.todos

    assert Enum.map(snap.main.conclusions, & &1.text) ==
             ["starting with a todo list.", "everything works."]

    GenServer.stop(coord)
  end

  test "subagent inner events are attributed to its own agent entry and the linked todo auto-completes",
       %{dir: dir} do
    sid = "int-#{System.unique_integer([:positive])}"
    {:ok, coord} = Coordinator.start_for(sid)

    parent_responses = [
      %Response{
        text: "Setting up.",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "todo_write",
            arguments: %{
              "todos" => [%{"content" => "explore the repo", "status" => "in_progress"}]
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "Delegating.",
        tool_calls: [
          %ToolCall{
            id: "t2",
            name: "spawn_agent",
            arguments: %{"prompt" => "explore everything", "todo" => "explore the repo"}
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "All done.", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn _ ->
      %Response{
        text: "Found the answer.\nCONCLUSION: repo uses phoenix.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end

    assert {:ok, _} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(parent_responses)],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
               coordinator: coord,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [responder: sub_responder],
                   tools: [],
                   memory: false
                 ]
               }
             )

    {:ok, snap} = Coordinator.snapshot(sid)

    # The subagent got its own entry, fed by its OWN loop's events.
    assert [agent] = snap.agents
    assert agent.status == :done
    assert Enum.any?(agent.conclusions, &(&1.text == "repo uses phoenix."))

    # Runtime-derived completion: the linked main todo flipped on success.
    assert [%{content: "explore the repo", status: :completed}] = snap.main.todos

    GenServer.stop(coord)
  end

  test "the subagent prompt suffix is appended to the sub's system prompt", %{dir: dir} do
    sid = "int-#{System.unique_integer([:positive])}"
    {:ok, coord} = Coordinator.start_for(sid)
    test_pid = self()

    parent_responses = [
      %Response{
        text: "Delegating.",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "do the step"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn request ->
      send(test_pid, {:sub_system_prompt, request.system_prompt})
      %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, _} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(parent_responses)],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.SpawnAgent],
               coordinator: coord,
               subagent_prompt_suffix: "You are a focused sub-agent. End with a summary.",
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [responder: sub_responder],
                   tools: [],
                   memory: false
                 ]
               }
             )

    assert_receive {:sub_system_prompt, sp}
    assert sp =~ "focused sub-agent"

    GenServer.stop(coord)
  end
end
