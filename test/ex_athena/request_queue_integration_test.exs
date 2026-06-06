defmodule ExAthena.RequestQueueIntegrationTest do
  use ExUnit.Case, async: false

  alias ExAthena.{RequestQueue, Response}

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_athena, :request_queue)
      Application.delete_env(:ex_athena, :mock)
    end)
  end

  describe "kill switch and missing-process behavior" do
    test "queue is bypassed and query succeeds when explicitly disabled" do
      Application.put_env(:ex_athena, :request_queue, enabled: false)

      assert {:ok, %Response{text: "pong"}} =
               ExAthena.query("hi", provider: :mock, mock: [text: "pong"])
    end

    test "query succeeds with no RequestQueue process running (acquire no-ops)" do
      # Enabled by default, but the GenServer isn't started in tests —
      # acquire/release degrade to no-ops rather than crashing.
      assert Process.whereis(RequestQueue) == nil

      assert {:ok, %Response{text: "ok"}} =
               ExAthena.query("hi", provider: :mock, mock: [text: "ok"])
    end
  end

  describe "opt-out with queue: false" do
    setup do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])
      start_supervised!(RequestQueue)
      :ok
    end

    test "queue: false bypasses acquire even when queue is enabled and at capacity" do
      # Occupy the only slot
      :ok = RequestQueue.acquire(:mock)
      assert RequestQueue.depth(:mock) == 1

      # With queue: false, this must not block
      assert {:ok, _} = ExAthena.query("hi", provider: :mock, mock: [text: "ok"], queue: false)

      RequestQueue.release(:mock)
    end

    test "queue: false bypasses acquire for stream" do
      :ok = RequestQueue.acquire(:mock)

      assert {:ok, _} =
               ExAthena.stream("hi", fn _ -> :ok end,
                 provider: :mock,
                 mock: [text: "ok"],
                 queue: false
               )

      RequestQueue.release(:mock)
    end
  end

  describe "concurrent cap enforcement" do
    setup do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])
      start_supervised!(RequestQueue)
      :ok
    end

    test "query blocks when at capacity and unblocks after release" do
      # Manually occupy the only slot
      :ok = RequestQueue.acquire(:mock)
      assert RequestQueue.depth(:mock) == 1

      test_pid = self()

      task =
        Task.async(fn ->
          result = ExAthena.query("hi", provider: :mock, mock: [text: "queued"])
          send(test_pid, {:done, result})
          result
        end)

      # Give the task time to attempt acquiring (it should be blocked)
      Process.sleep(50)
      refute_received {:done, _}
      assert RequestQueue.depth(:mock) == 1

      # Release the slot — query should unblock
      RequestQueue.release(:mock)

      assert_receive {:done, {:ok, %Response{text: "queued"}}}, 1_000
      assert RequestQueue.depth(:mock) == 0
      Task.await(task)
    end

    test "stream blocks when at capacity and unblocks after release" do
      :ok = RequestQueue.acquire(:mock)

      test_pid = self()

      task =
        Task.async(fn ->
          result =
            ExAthena.stream("hi", fn _ -> :ok end, provider: :mock, mock: [text: "streamed"])

          send(test_pid, {:done, result})
          result
        end)

      Process.sleep(50)
      refute_received {:done, _}

      RequestQueue.release(:mock)
      assert_receive {:done, {:ok, _}}, 1_000
      Task.await(task)
    end

    test "slot is held for the full duration of streaming" do
      test_pid = self()

      # Callback blocks on first text_delta so we can observe depth during streaming
      callback = fn
        %ExAthena.Streaming.Event{type: :text_delta} ->
          send(test_pid, :streaming_started)

          receive do
            :continue -> :ok
          end

        _ ->
          :ok
      end

      events = [%ExAthena.Streaming.Event{type: :text_delta, data: "hi"}]

      task =
        Task.async(fn ->
          ExAthena.stream("hi", callback,
            provider: :mock,
            mock: [text: "hi"],
            mock_events: events
          )
        end)

      assert_receive :streaming_started, 1_000
      assert RequestQueue.depth(:mock) == 1

      send(task.pid, :continue)
      assert {:ok, _} = Task.await(task, 1_000)
      assert RequestQueue.depth(:mock) == 0
    end

    test "loop provider calls acquire one slot PER CALL, not per run" do
      test_pid = self()

      :telemetry.attach_many(
        "per-call-granularity-#{System.unique_integer([:positive])}",
        [
          [:ex_athena, :request_queue, :acquired],
          [:ex_athena, :request_queue, :released]
        ],
        fn event, _m, %{provider: :mock}, _ -> send(test_pid, {:tele, List.last(event)}) end,
        nil
      )

      dir = Path.join(System.tmp_dir!(), "rq_loop_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "hello.txt"), "hi")

      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %ExAthena.Response{
              text: "",
              tool_calls: [
                %ExAthena.Messages.ToolCall{
                  id: "c1",
                  name: "read",
                  arguments: %{"path" => "hello.txt"}
                }
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %ExAthena.Response{
              text: "done",
              tool_calls: [],
              finish_reason: :stop,
              provider: :mock
            }
        end
      end

      assert {:ok, _} =
               ExAthena.run("go",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read]
               )

      # Two provider calls → exactly two acquire/release pairs (per-call
      # granularity; a run-level hold would emit just one pair).
      assert_receive {:tele, :acquired}
      assert_receive {:tele, :released}
      assert_receive {:tele, :acquired}
      assert_receive {:tele, :released}
      refute_received {:tele, :acquired}
      assert RequestQueue.depth(:mock) == 0
    end

    test "two concurrent loops serialize their provider calls at max_depth 1" do
      test_pid = self()

      # Responder signals entry, then blocks until told to continue — proving
      # the second loop's provider call cannot start while the first holds the slot.
      responder = fn _request ->
        send(test_pid, {:entered, self()})

        receive do
          :continue -> :ok
        end

        %ExAthena.Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end

      opts = [provider: :mock, mock: [responder: responder], tools: []]

      t1 = Task.async(fn -> ExAthena.Loop.run("a", opts) end)
      t2 = Task.async(fn -> ExAthena.Loop.run("b", opts) end)

      assert_receive {:entered, first}, 1_000
      # Only one call may be in flight — the second loop's provider call is
      # queued, so no second :entered can arrive while the first holds its slot.
      refute_receive {:entered, _}, 100

      send(first, :continue)
      assert_receive {:entered, second}, 1_000
      send(second, :continue)

      assert {:ok, _} = Task.await(t1)
      assert {:ok, _} = Task.await(t2)
      assert RequestQueue.depth(:mock) == 0
    end

    test "the loop emits {:queue_wait, ...} events around a blocked acquire" do
      test_pid = self()
      on_event = fn ev -> send(test_pid, {:athena, ev}) end

      # Occupy the only slot so the loop's provider call must queue.
      :ok = RequestQueue.acquire(:mock)

      task =
        Task.async(fn ->
          ExAthena.Loop.run("hi",
            provider: :mock,
            mock: [text: "done"],
            tools: [],
            on_event: on_event
          )
        end)

      assert_receive {:athena, {:queue_wait, %{provider: :mock, status: :waiting}}}, 1_000

      RequestQueue.release(:mock)

      assert_receive {:athena,
                      {:queue_wait, %{provider: :mock, status: :acquired, waited_ms: ms}}}
                     when is_integer(ms),
                     1_000

      assert {:ok, _} = Task.await(task)
    end

    test "returns {:error, :request_queue_timeout} when acquire times out" do
      # Occupy the slot so acquire will block
      :ok = RequestQueue.acquire(:mock)

      # Use a very short timeout so the test doesn't wait 5 seconds
      result =
        ExAthena.query("hi",
          provider: :mock,
          mock: [text: "never"],
          queue_timeout: 20
        )

      assert result == {:error, :request_queue_timeout}

      RequestQueue.release(:mock)
    end
  end
end
