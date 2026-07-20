defmodule ExAthena.Modes.OrchestratePermissionGateTest do
  @moduledoc """
  Issue #130 — orchestrate runtime auto-delegation must run through the
  same pre-tool gate as model-initiated calls: `disallowed_tools:
  ["spawn_agent"]` and PreToolUse deny hooks must stop it.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "orch_gate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Plan, then two spawn-less executing turns (triggers the watchdog),
  # then stop. Never calls spawn_agent itself.
  defp spawnless_responder do
    counter = :counters.new(1, [:atomics])

    todos_args = %{
      "todos" => [%{"content" => "write the blog post", "status" => "pending"}]
    }

    fn _req ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      case n do
        1 ->
          %Response{text: "the plan", tool_calls: [], finish_reason: :stop, provider: :mock}

        n when n in [2, 3] ->
          %Response{
            text: "Organizing todos.",
            tool_calls: [%ToolCall{id: "t#{n}", name: "todo_write", arguments: todos_args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{
            text: "done\nCONCLUSION: stopping.",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }
      end
    end
  end

  defp run_orchestrator(dir, extra_opts) do
    test_pid = self()

    sub_responder = fn _request ->
      send(test_pid, :subagent_ran)
      %Response{text: "worker done", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    on_event = fn ev -> send(test_pid, {:event, ev}) end

    {:ok, result} =
      Loop.run(
        "go",
        Keyword.merge(
          [
            provider: :mock,
            mock: [responder: spawnless_responder()],
            cwd: dir,
            memory: false,
            tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
            mode: :orchestrate,
            on_event: on_event,
            assigns: %{
              spawn_agent_opts: [
                provider: :mock,
                mock: [responder: sub_responder],
                memory: false
              ]
            }
          ],
          extra_opts
        )
      )

    result
  end

  defp blocked_note?(result) do
    Enum.any?(result.messages, fn
      %{role: :user, content: c} when is_binary(c) ->
        c =~ "orchestration runtime" and c =~ "blocked"

      _ ->
        false
    end)
  end

  test "auto-delegation respects disallowed_tools: [\"spawn_agent\"]", %{dir: dir} do
    result = run_orchestrator(dir, disallowed_tools: ["spawn_agent"])

    refute_received :subagent_ran
    refute_received {:event, {:subagent_spawn, _}}
    assert blocked_note?(result)
  end

  test "auto-delegation respects a PreToolUse deny hook on spawn_agent", %{dir: dir} do
    hooks = %{
      PreToolUse: [
        %{matcher: "spawn_agent", hooks: [fn _input, _id -> {:deny, "no delegation"} end]}
      ]
    }

    result = run_orchestrator(dir, hooks: hooks)

    refute_received :subagent_ran
    refute_received {:event, {:subagent_spawn, _}}
    assert blocked_note?(result)
  end
end
