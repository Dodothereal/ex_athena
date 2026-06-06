defmodule ExAthena.Orchestrator.CoordinatorTest do
  @moduledoc """
  Per-run blackboard GenServer: Registry-named, DynamicSupervisor-started,
  cast-only ingest, monitored send/2 subscribers with batched snapshots.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Orchestrator.Coordinator
  alias ExAthena.Messages.ToolCall

  defp unique_sid, do: "coord-test-#{System.unique_integer([:positive])}"

  describe "lifecycle" do
    test "start_for/2 registers by session id and is idempotent" do
      sid = unique_sid()

      assert {:ok, pid} = Coordinator.start_for(sid)
      assert Coordinator.whereis(sid) == pid
      assert {:ok, ^pid} = Coordinator.start_for(sid)

      GenServer.stop(pid)
    end

    test "whereis/1 returns nil for unknown sessions" do
      assert Coordinator.whereis("nope-#{System.unique_integer()}") == nil
    end
  end

  describe "event ingest and snapshots" do
    test "main events fold into the main agent info" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      Coordinator.notify(pid, :main, {:iteration, 2})

      Coordinator.notify(
        pid,
        :main,
        {:tool_call, %ToolCall{id: "t", name: "read", arguments: %{}}}
      )

      Coordinator.notify(
        pid,
        :main,
        {:conclusion, %{iteration: 2, text: "found it", source: :stated}}
      )

      {:ok, snap} = Coordinator.snapshot(sid)
      assert snap.main.iteration == 2
      assert snap.main.current_action == "tool: read"
      assert [%{text: "found it"}] = snap.main.conclusions

      GenServer.stop(pid)
    end

    test "subagent spawn/result events open and close agent entries in order" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-a", prompt: "step A"}})
      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-b", prompt: "step B"}})

      Coordinator.notify(
        pid,
        "sub-a",
        {:conclusion, %{iteration: 0, text: "did A", source: :stated}}
      )

      Coordinator.notify(pid, :main, {:subagent_result, %{id: "sub-a", text: "summary A"}})

      {:ok, snap} = Coordinator.snapshot(sid)
      assert [a, b] = snap.agents
      assert a.id == "sub-a" and b.id == "sub-b"
      assert a.status == :done
      assert b.status == :running
      assert a.prompt_summary == "step A"
      assert [%{text: "did A"}] = a.conclusions
      # The worker's final summary is kept on its entry for the UI.
      assert a.result == "summary A"

      GenServer.stop(pid)
    end

    test "a failure note is stored on the agent entry" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-x", prompt: "explore"}})

      Coordinator.notify(
        pid,
        "sub-x",
        {:result_note, "did not finish (error_max_turns): - found services dir"}
      )

      {:ok, snap} = Coordinator.snapshot(sid)
      [agent] = snap.agents
      assert agent.result =~ "did not finish"
      assert agent.result =~ "found services dir"

      GenServer.stop(pid)
    end

    test "agent_meta enriches an entry and links a todo (by content) that auto-completes on success" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      Coordinator.notify(
        pid,
        :main,
        {:todos, [%{"content" => "delegate step A", "status" => "in_progress"}]}
      )

      Coordinator.notify(
        pid,
        "sub-a",
        {:agent_meta, %{prompt: "step A", name: "explore", linked_todo: "delegate step A"}}
      )

      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-a", prompt: "step A"}})
      Coordinator.notify(pid, :main, {:subagent_result, %{id: "sub-a", text: "done"}})

      {:ok, snap} = Coordinator.snapshot(sid)
      assert [%{status: :completed}] = snap.main.todos
      assert [%{name: "explore", status: :done}] = snap.agents

      GenServer.stop(pid)
    end

    test "a worker without an explicit todo link is fuzzily attached to the matching task" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      Coordinator.notify(
        pid,
        :main,
        {:todos,
         [
           %{
             "content" =>
               "Explore repository structure to identify patterns for services, products, and blog posts",
             "status" => "in_progress"
           },
           %{"content" => "Publish the blog post", "status" => "pending"}
         ]}
      )

      # The model spawned without `todo:` — only the prompt hints which task.
      Coordinator.notify(
        pid,
        "sub-a",
        {:agent_meta,
         %{
           prompt:
             "Explore the repository structure to identify how services, products, and blog posts are organized.",
           name: nil,
           linked_todo: nil
         }}
      )

      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-a", prompt: "explore"}})

      {:ok, snap} = Coordinator.snapshot(sid)
      [agent] = snap.agents
      assert agent.linked_todo =~ "Explore repository structure"

      # …and runtime-derived completion works through the fuzzy link too.
      Coordinator.notify(pid, :main, {:subagent_result, %{id: "sub-a", text: "done"}})
      {:ok, snap} = Coordinator.snapshot(sid)
      assert [%{status: :completed}, %{status: :pending}] = snap.main.todos

      GenServer.stop(pid)
    end

    test "an unrelated worker prompt stays unlinked" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      Coordinator.notify(
        pid,
        :main,
        {:todos, [%{"content" => "Publish the blog post", "status" => "pending"}]}
      )

      Coordinator.notify(
        pid,
        "sub-b",
        {:agent_meta, %{prompt: "Compute fibonacci numbers quickly", name: nil, linked_todo: nil}}
      )

      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-b", prompt: "fib"}})

      {:ok, snap} = Coordinator.snapshot(sid)
      [agent] = snap.agents
      assert agent.linked_todo == nil

      GenServer.stop(pid)
    end

    test "subscribe/2 returns the snapshot and then streams batched updates" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      assert {:ok, snap} = Coordinator.subscribe(sid, self())
      assert snap.main.iteration == 0

      Coordinator.notify(pid, :main, {:iteration, 1})
      Coordinator.notify(pid, :main, {:iteration, 2})

      # Both notifies fold into ONE batched update (100 ms flush).
      assert_receive {:orchestrator_update, ^sid, update}, 1_000
      assert update.main.iteration == 2
      refute_received {:orchestrator_update, ^sid, _}

      GenServer.stop(pid)
    end

    test "a dead subscriber is dropped without crashing the coordinator" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)

      subscriber = spawn(fn -> receive(do: (:never -> :ok)) end)
      {:ok, _} = Coordinator.subscribe(sid, subscriber)
      Process.exit(subscriber, :kill)

      Coordinator.notify(pid, :main, {:iteration, 1})
      # Snapshot call doubles as a liveness check after the flush cycle.
      {:ok, snap} = Coordinator.snapshot(sid)
      assert snap.main.iteration == 1

      GenServer.stop(pid)
    end

    test "notify to a dead coordinator is harmless (cast)" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid)
      GenServer.stop(pid)

      assert :ok = Coordinator.notify(pid, :main, {:iteration, 1})
    end
  end

  describe "run monitoring and retention" do
    test "when the attached run dies, non-terminal agents are failed and the snapshot survives" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid, retention_ms: 60_000)

      run =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      :ok = Coordinator.attach_run(pid, run)
      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-a", prompt: "x"}})
      Coordinator.notify(pid, :main, {:subagent_result, %{id: "sub-a", text: "ok"}})
      Coordinator.notify(pid, :main, {:subagent_spawn, %{id: "sub-b", prompt: "y"}})

      {:ok, _} = Coordinator.subscribe(sid, self())
      Process.exit(run, :kill)

      # The :DOWN marks agents failed and triggers a flush — wait for it.
      assert_receive {:orchestrator_update, ^sid, %{main: %{status: :failed}}}, 1_000

      {:ok, snap} = Coordinator.snapshot(sid)
      assert snap.main.status == :failed
      assert Enum.find(snap.agents, &(&1.id == "sub-a")).status == :done
      assert Enum.find(snap.agents, &(&1.id == "sub-b")).status == :failed

      GenServer.stop(pid)
    end

    test "the coordinator retires after the retention window" do
      sid = unique_sid()
      {:ok, pid} = Coordinator.start_for(sid, retention_ms: 50)

      run = spawn(fn -> :ok end)
      ref = Process.monitor(run)
      :ok = Coordinator.attach_run(pid, run)
      assert_receive {:DOWN, ^ref, :process, ^run, _}

      coord_ref = Process.monitor(pid)
      assert_receive {:DOWN, ^coord_ref, :process, ^pid, :normal}, 1_000

      # Registry unregistration is asynchronous after the :DOWN; either the
      # name is gone already or it still maps to the (dead) pid for a moment.
      case Coordinator.whereis(sid) do
        nil -> :ok
        ^pid -> refute Process.alive?(pid)
      end
    end
  end
end
