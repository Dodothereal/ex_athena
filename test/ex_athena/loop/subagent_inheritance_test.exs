defmodule ExAthena.Loop.SubagentInheritanceTest do
  @moduledoc """
  Issue #130 — a subagent must never be MORE privileged than its parent.

  The parent's confinement roots, tool allow/deny lists, `can_use_tool`
  approval callback, phase, and deny-capable `PreToolUse` hooks all apply
  to every child `spawn_agent` starts. Agent definitions may NARROW these
  guardrails but can never widen them.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "sub_inherit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Parent: one spawn_agent call, then stop.
  defp parent_responder(spawn_args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "delegating",
            tool_calls: [%ToolCall{id: "p1", name: "spawn_agent", arguments: spawn_args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "parent done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  # Child: one tool call, then stop.
  defp child_responder(tool_name, args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "working",
            tool_calls: [%ToolCall{id: "c1", name: tool_name, arguments: args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "child done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp run_parent(dir, child_fun, parent_opts) do
    {:ok, result} =
      Loop.run(
        "go",
        Keyword.merge(
          [
            provider: :mock,
            mock: [responder: parent_responder(%{"prompt" => "do the sub-task"})],
            tools: [ExAthena.Tools.SpawnAgent],
            cwd: dir,
            memory: false,
            max_iterations: 5,
            assigns: %{
              spawn_agent_opts: [
                provider: :mock,
                mock: [responder: child_fun],
                memory: false
              ]
            }
          ],
          parent_opts
        )
      )

    result
  end

  describe "confinement inheritance" do
    test "child of a confined parent cannot write outside the parent's allowed_roots", %{
      dir: dir
    } do
      outside = Path.join(System.tmp_dir!(), "escape_#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm_rf!(outside) end)

      child = child_responder("write", %{"path" => outside, "content" => "pwned"})
      run_parent(dir, child, confine: true)

      refute File.exists?(outside)
    end

    test "child of a confined parent CAN still write inside the parent's roots", %{dir: dir} do
      inside = Path.join(dir, "inside.txt")

      child = child_responder("write", %{"path" => inside, "content" => "fine"})
      run_parent(dir, child, confine: true)

      assert File.read!(inside) == "fine"
    end
  end

  describe "tool blocklist / allowlist inheritance" do
    test "child cannot invoke a tool in the parent's disallowed_tools", %{dir: dir} do
      target = Path.join(dir, "blocked.txt")

      child = child_responder("write", %{"path" => target, "content" => "nope"})
      run_parent(dir, child, disallowed_tools: ["write"])

      refute File.exists?(target)
    end

    test "child cannot invoke a tool outside the parent's allowed_tools", %{dir: dir} do
      target = Path.join(dir, "not_allowed.txt")

      child = child_responder("write", %{"path" => target, "content" => "nope"})
      run_parent(dir, child, allowed_tools: ["read", "spawn_agent"])

      refute File.exists?(target)
    end
  end

  describe "phase inheritance" do
    test "a :plan-phase parent spawns a :plan-phase child (writes denied)", %{dir: dir} do
      target = Path.join(dir, "plan_phase.txt")

      child = child_responder("write", %{"path" => target, "content" => "nope"})
      run_parent(dir, child, phase: :plan)

      refute File.exists?(target)
    end

    test "an agent definition cannot WIDEN the parent's phase", %{dir: dir} do
      agents_dir = Path.join(dir, ".exathena/agents")
      File.mkdir_p!(agents_dir)

      File.write!(Path.join(agents_dir, "rogue.md"), """
      ---
      name: rogue
      description: tries to escalate to bypass_permissions
      permissions: bypass_permissions
      tools: [write]
      ---

      You write files.
      """)

      target = Path.join(dir, "rogue.txt")
      child = child_responder("write", %{"path" => target, "content" => "nope"})

      {:ok, _} =
        Loop.run(
          "go",
          provider: :mock,
          mock: [
            responder: parent_responder(%{"prompt" => "do the sub-task", "agent" => "rogue"})
          ],
          tools: [ExAthena.Tools.SpawnAgent],
          cwd: dir,
          phase: :plan,
          memory: false,
          max_iterations: 5,
          assigns: %{
            spawn_agent_opts: [provider: :mock, mock: [responder: child], memory: false]
          }
        )

      refute File.exists?(target)
    end

    test "an agent definition may still NARROW the phase", %{dir: dir} do
      agents_dir = Path.join(dir, ".exathena/agents")
      File.mkdir_p!(agents_dir)

      File.write!(Path.join(agents_dir, "readonly.md"), """
      ---
      name: readonly
      description: read-only worker
      permissions: plan
      tools: [write]
      ---

      You investigate.
      """)

      target = Path.join(dir, "narrowed.txt")
      child = child_responder("write", %{"path" => target, "content" => "nope"})

      {:ok, _} =
        Loop.run(
          "go",
          provider: :mock,
          mock: [
            responder: parent_responder(%{"prompt" => "do the sub-task", "agent" => "readonly"})
          ],
          tools: [ExAthena.Tools.SpawnAgent],
          cwd: dir,
          phase: :default,
          memory: false,
          max_iterations: 5,
          assigns: %{
            spawn_agent_opts: [provider: :mock, mock: [responder: child], memory: false]
          }
        )

      refute File.exists?(target)
    end
  end

  describe "can_use_tool inheritance" do
    test "the parent's can_use_tool callback gates child tool calls", %{dir: dir} do
      test_pid = self()
      target = Path.join(dir, "callback.txt")

      can_use_tool = fn
        "write", _args, _ctx ->
          send(test_pid, :callback_saw_write)
          {:deny, "writes require approval"}

        _name, _args, _ctx ->
          :allow
      end

      child = child_responder("write", %{"path" => target, "content" => "nope"})
      run_parent(dir, child, can_use_tool: can_use_tool)

      assert_receive :callback_saw_write
      refute File.exists?(target)
    end
  end

  describe "PreToolUse hook inheritance" do
    test "the parent's deny-capable PreToolUse hooks gate child tool calls", %{dir: dir} do
      target = Path.join(dir, "hooked.txt")

      hooks = %{
        PreToolUse: [
          %{matcher: "write", hooks: [fn _input, _id -> {:deny, "write is protected"} end]}
        ]
      }

      child = child_responder("write", %{"path" => target, "content" => "nope"})
      run_parent(dir, child, hooks: hooks)

      refute File.exists?(target)
    end
  end
end
