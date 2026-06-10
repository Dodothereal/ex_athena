defmodule ExAthena.Loop.NamedSubagentTest do
  @moduledoc """
  PR4 — verifies that a `SpawnAgent` call with `agent: <name>` resolves to
  the matching definition, that sidechain JSONL transcripts get written,
  and that SubagentStart hook payloads carry the agent name + isolation
  decision.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "named_sub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp parent_responder_calls_subagent_then_stops(args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "calling sub",
            tool_calls: [%ToolCall{id: "c1", name: "spawn_agent", arguments: args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        2 ->
          %Response{text: "all done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp subagent_responder_finishes_immediately do
    fn _req ->
      %Response{text: "subagent finished", finish_reason: :stop, provider: :mock}
    end
  end

  defp tool_names(tools) do
    Enum.map(tools || [], fn t ->
      t[:name] || t["name"] || get_in(t, [:function, :name]) || get_in(t, ["function", "name"])
    end)
  end

  test "a named agent's declared tools are respected, plus the always-on todo_write", %{dir: dir} do
    parent = self()

    capture_tools = fn req ->
      send(parent, {:sub_tools, tool_names(req.tools)})
      %Response{text: "done", finish_reason: :stop, provider: :mock}
    end

    {:ok, _result} =
      Loop.run(
        "do a thing",
        provider: :mock,
        mock: [
          responder:
            parent_responder_calls_subagent_then_stops(%{
              "prompt" => "explore the repo",
              "agent" => "explore"
            })
        ],
        tools: [ExAthena.Tools.SpawnAgent],
        cwd: dir,
        memory: false,
        assigns: %{
          spawn_agent_opts: [provider: :mock, mock: [responder: capture_tools], memory: false]
        },
        max_iterations: 5
      )

    assert_receive {:sub_tools, names}

    # explore.md declares: read, glob, grep, web_fetch, web_search — those win.
    assert "read" in names
    assert "grep" in names
    assert "web_search" in names
    # todo_write is always granted (worker contract) even though explore.md
    # does not list it.
    assert "todo_write" in names
    # The full builtin set must NOT leak in — a read-only explorer never gets
    # bash/write/edit, and never spawn_agent/plan_mode (depth-1).
    refute "bash" in names
    refute "write" in names
    refute "edit" in names
    refute "spawn_agent" in names
  end

  test "agent: \"explore\" resolves to the builtin definition", %{dir: dir} do
    ref = make_ref()
    parent = self()

    hooks = %{
      SubagentStart: [
        fn p, _ ->
          send(parent, {ref, :start, p[:agent], p[:isolation]})
          :ok
        end
      ]
    }

    {:ok, result} =
      Loop.run(
        "do a thing",
        provider: :mock,
        mock: [
          responder:
            parent_responder_calls_subagent_then_stops(%{
              "prompt" => "explore the repo",
              "agent" => "explore"
            })
        ],
        tools: [ExAthena.Tools.SpawnAgent],
        cwd: dir,
        hooks: hooks,
        memory: false,
        # Subagent inherits the parent's mock provider via :spawn_agent_opts.
        assigns: %{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: subagent_responder_finishes_immediately()],
            tools: [],
            memory: false
          ]
        },
        max_iterations: 5
      )

    assert result.finish_reason == :stop
    assert_receive {^ref, :start, "explore", isolation}
    # In a non-git tmpdir, isolation falls back to in_process.
    assert match?({:in_process, _}, isolation)
  end

  test "spawn writes a sidechain JSONL transcript", %{dir: dir} do
    {:ok, _} =
      Loop.run(
        "do a thing",
        provider: :mock,
        mock: [
          responder:
            parent_responder_calls_subagent_then_stops(%{
              "prompt" => "go",
              "agent" => "general"
            })
        ],
        tools: [ExAthena.Tools.SpawnAgent],
        cwd: dir,
        memory: false,
        session_id: "fixed-parent",
        assigns: %{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: subagent_responder_finishes_immediately()],
            tools: [],
            memory: false
          ]
        }
      )

    sidechain_dir = Path.join([dir, ".exathena", "sessions", "fixed-parent", "sidechains"])
    assert File.dir?(sidechain_dir)

    [file] = File.ls!(sidechain_dir)
    assert file =~ "subagent_"

    body = File.read!(Path.join(sidechain_dir, file))
    assert body =~ "subagent finished"
    assert body =~ "\"parent_session_id\":\"fixed-parent\""
  end

  test "unknown agent name silently falls back to inline opts", %{dir: dir} do
    {:ok, result} =
      Loop.run(
        "do a thing",
        provider: :mock,
        mock: [
          responder:
            parent_responder_calls_subagent_then_stops(%{
              "prompt" => "go",
              "agent" => "this-agent-does-not-exist"
            })
        ],
        tools: [ExAthena.Tools.SpawnAgent],
        cwd: dir,
        memory: false,
        assigns: %{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: subagent_responder_finishes_immediately()],
            tools: [],
            memory: false
          ]
        }
      )

    assert result.finish_reason == :stop
  end
end
