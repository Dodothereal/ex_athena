defmodule ExAthena.RequestQueueIntegrationTest do
  use ExUnit.Case, async: false

  alias ExAthena.{RequestQueue, Response}

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_athena, :request_queue)
      Application.delete_env(:ex_athena, :mock)
    end)
  end

  describe "default-disabled behavior" do
    test "queue is bypassed and query succeeds when request_queue is not enabled" do
      assert {:ok, %Response{text: "pong"}} =
               ExAthena.query("hi", provider: :mock, mock: [text: "pong"])
    end

    test "query succeeds with no RequestQueue process running" do
      # Verify no RequestQueue process is running
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
