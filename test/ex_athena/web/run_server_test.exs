defmodule ExAthena.Web.RunServerTest do
  # Not async: the registry/supervisor are globally named (mirroring how
  # `mix athena.web` starts them), so the module owns those names alone.
  use ExUnit.Case, async: false

  alias ExAthena.Messages
  alias ExAthena.Web.RunServer

  setup do
    start_supervised!({Registry, keys: :unique, name: ExAthena.Web.RunRegistry})

    start_supervised!(
      {DynamicSupervisor, name: ExAthena.Web.RunSupervisor, strategy: :one_for_one}
    )

    :ok
  end

  # A run whose provider blocks until the test sends `:finish`, so the run is
  # deterministically "in flight" while we attach/inspect. The responder runs
  # inside the run Task, so `self()` there is the task pid we unblock.
  defp blocking_run(session_id, assistant_msg_id \\ "amsg") do
    test_pid = self()

    responder = fn _request ->
      send(test_pid, {:run_task, self()})

      receive do
        :finish ->
          %ExAthena.Response{
            text: "final answer",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }
      end
    end

    {:ok, _pid} =
      RunServer.start_run(session_id, %{
        run_opts: [
          provider: :mock,
          mock: [responder: responder],
          messages: [Messages.user("hi")]
        ],
        assistant_msg_id: assistant_msg_id,
        run_sid: "#{session_id}-run-#{assistant_msg_id}"
      })

    assert_receive {:run_task, task}, 2_000
    task
  end

  test "attaching mid-run returns a live snapshot scoped to the run" do
    sid = "s-snapshot"
    task = blocking_run(sid)

    assert RunServer.running?(sid)
    assert {:ok, snap} = RunServer.attach(sid, self())
    assert snap.streaming
    assert snap.pending_assistant_msg_id == "amsg"
    assert snap.run_sid == "s-snapshot-run-amsg"

    send(task, :finish)
    assert_receive {:athena_done, %{text: "final answer"}}, 2_000
  end

  test "a finished run is no longer attachable (caller loads the saved session)" do
    sid = "s-finished"
    task = blocking_run(sid)
    {:ok, _} = RunServer.attach(sid, self())

    send(task, :finish)
    assert_receive {:athena_done, _result}, 2_000

    refute RunServer.running?(sid)
    assert {:error, :not_running} = RunServer.attach(sid, self())
  end

  test "the run survives the original subscriber dying and a reconnect re-attaches" do
    sid = "s-reconnect"
    task = blocking_run(sid)

    # The original "LiveView" attaches, then dies (websocket drop).
    original =
      spawn(fn ->
        RunServer.attach(sid, self())
        receive do: (:never -> :ok)
      end)

    ref = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^ref, :process, ^original, :killed}, 1_000

    # The run is still in flight despite no UI attached.
    assert RunServer.running?(sid)

    # The reconnecting LiveView (this test pid) re-attaches and receives the
    # completion it would otherwise have missed.
    assert {:ok, %{streaming: true}} = RunServer.attach(sid, self())
    send(task, :finish)
    assert_receive {:athena_done, %{text: "final answer"}}, 2_000
  end

  test "stop_run kills the in-flight run and retires the server" do
    sid = "s-stop"
    server = RunServer.whereis(sid)
    assert is_nil(server)

    _task = blocking_run(sid)
    server = RunServer.whereis(sid)
    sref = Process.monitor(server)

    :ok = RunServer.stop_run(sid)
    assert_receive {:DOWN, ^sref, :process, ^server, :normal}, 5_000
    refute RunServer.running?(sid)
  end
end
