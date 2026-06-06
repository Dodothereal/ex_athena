defmodule ExAthena.RequestQueueTest do
  use ExUnit.Case, async: false

  alias ExAthena.RequestQueue

  setup do
    start_supervised!(RequestQueue)
    :ok
  end

  describe "depth/1" do
    test "returns 0 for a provider with no active slots" do
      assert RequestQueue.depth(:ollama) == 0
    end

    test "returns 0 for unknown providers" do
      assert RequestQueue.depth(:unknown_provider_xyz) == 0
    end
  end

  describe "acquire/1" do
    test "returns :ok and increments depth" do
      assert :ok = RequestQueue.acquire(:openai)
      assert RequestQueue.depth(:openai) == 1
    end

    test "allows multiple concurrent slots up to the max depth" do
      max = ExAthena.Config.request_queue_max_depth(:openai)

      for _ <- 1..max do
        assert :ok = RequestQueue.acquire(:openai)
      end

      assert RequestQueue.depth(:openai) == max
    end

    test "blocks when max depth is reached and unblocks when a slot is released" do
      max = ExAthena.Config.request_queue_max_depth(:ollama)
      for _ <- 1..max, do: :ok = RequestQueue.acquire(:ollama)

      test_pid = self()

      task =
        Task.async(fn ->
          result = RequestQueue.acquire(:ollama)
          send(test_pid, {:acquired, result})
          result
        end)

      Process.sleep(30)
      assert RequestQueue.depth(:ollama) == max

      RequestQueue.release(:ollama)
      assert_receive {:acquired, :ok}, 1_000

      Task.shutdown(task, :brutal_kill)
    end

    test "multiple providers are independent" do
      :ok = RequestQueue.acquire(:ollama)
      :ok = RequestQueue.acquire(:openai)
      assert RequestQueue.depth(:ollama) == 1
      assert RequestQueue.depth(:openai) == 1
    end
  end

  describe "release/1" do
    test "decrements depth after acquire" do
      :ok = RequestQueue.acquire(:ollama)
      :ok = RequestQueue.release(:ollama)
      assert RequestQueue.depth(:ollama) == 0
    end

    test "depth does not go below zero on extra release" do
      :ok = RequestQueue.release(:ollama)
      assert RequestQueue.depth(:ollama) == 0
    end

    test "releasing one slot allows a queued waiter to proceed" do
      max = ExAthena.Config.request_queue_max_depth(:ollama)
      for _ <- 1..max, do: :ok = RequestQueue.acquire(:ollama)

      test_pid = self()

      _waiter =
        spawn(fn ->
          :ok = RequestQueue.acquire(:ollama)
          send(test_pid, :waiter_acquired)
        end)

      Process.sleep(20)
      :ok = RequestQueue.release(:ollama)
      assert_receive :waiter_acquired, 500
    end
  end

  describe "with_slot/3" do
    setup do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])

      on_exit(fn ->
        Application.delete_env(:ex_athena, :request_queue)
        Application.delete_env(:ex_athena, :mock)
      end)

      :ok
    end

    test "runs the fun inside an acquired slot and releases afterwards" do
      assert RequestQueue.depth(:mock) == 0

      result =
        RequestQueue.with_slot(:mock, fn ->
          assert RequestQueue.depth(:mock) == 1
          :did_run
        end)

      assert result == :did_run
      assert RequestQueue.depth(:mock) == 0
    end

    test "releases the slot when the fun raises" do
      assert_raise RuntimeError, fn ->
        RequestQueue.with_slot(:mock, fn -> raise "boom" end)
      end

      assert RequestQueue.depth(:mock) == 0
    end

    test "passes through without acquiring for nil or module providers" do
      assert RequestQueue.with_slot(nil, fn -> RequestQueue.depth(:mock) end) == 0
      assert RequestQueue.with_slot(SomeModule, fn -> RequestQueue.depth(:mock) end) == 0
    end

    test "queue: false opt bypasses the slot" do
      :ok = RequestQueue.acquire(:mock)

      assert RequestQueue.with_slot(:mock, fn -> :ran end, queue: false) == :ran

      RequestQueue.release(:mock)
    end

    test "passes through when the queue feature is disabled" do
      Application.put_env(:ex_athena, :request_queue, enabled: false)

      assert RequestQueue.with_slot(:mock, fn -> RequestQueue.depth(:mock) end) == 0
    end

    test "returns {:error, :request_queue_timeout} when the slot can't be acquired in time" do
      :ok = RequestQueue.acquire(:mock)

      assert RequestQueue.with_slot(:mock, fn -> :never end, timeout: 20) ==
               {:error, :request_queue_timeout}

      RequestQueue.release(:mock)
    end

    test "emits wait/acquired/released telemetry" do
      test_pid = self()

      :telemetry.attach_many(
        "with-slot-telemetry-#{System.unique_integer([:positive])}",
        [
          [:ex_athena, :request_queue, :wait],
          [:ex_athena, :request_queue, :acquired],
          [:ex_athena, :request_queue, :released]
        ],
        fn event, measurements, meta, _ -> send(test_pid, {:tele, event, measurements, meta}) end,
        nil
      )

      RequestQueue.with_slot(:mock, fn -> :ok end)

      assert_receive {:tele, [:ex_athena, :request_queue, :wait], _, %{provider: :mock}}
      assert_receive {:tele, [:ex_athena, :request_queue, :acquired], _, %{provider: :mock}}
      assert_receive {:tele, [:ex_athena, :request_queue, :released], _, %{provider: :mock}}
    end

    test "on_wait callback fires :waiting then {:acquired, ms} only when the call blocked" do
      test_pid = self()
      on_wait = fn status -> send(test_pid, {:wait_status, status}) end

      # Free slot: no on_wait callbacks at all.
      RequestQueue.with_slot(:mock, fn -> :ok end, on_wait: on_wait)
      refute_received {:wait_status, _}

      # Occupied slot: :waiting fires, then {:acquired, ms} once granted.
      :ok = RequestQueue.acquire(:mock)

      task =
        Task.async(fn ->
          RequestQueue.with_slot(:mock, fn -> :ran end, on_wait: on_wait, timeout: 1_000)
        end)

      assert_receive {:wait_status, :waiting}, 500
      RequestQueue.release(:mock)
      assert_receive {:wait_status, {:acquired, ms}} when is_integer(ms), 500
      assert Task.await(task) == :ran
    end
  end

  describe "holder crash safety" do
    test "a slot is reclaimed when its holder dies without releasing" do
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])
      on_exit(fn -> Application.delete_env(:ex_athena, :mock) end)

      test_pid = self()

      holder =
        spawn(fn ->
          :ok = RequestQueue.acquire(:mock)
          send(test_pid, :acquired)

          receive do
            :never -> :ok
          end
        end)

      assert_receive :acquired
      assert RequestQueue.depth(:mock) == 1

      # Brutal kill: no after/exit handlers run in the holder.
      Process.exit(holder, :kill)

      # A blocking acquire is the synchronization point: it can only succeed
      # once the queue has processed the holder's :DOWN and reclaimed the slot.
      assert :ok = RequestQueue.acquire(:mock, 1_000)
      assert RequestQueue.depth(:mock) == 1
      RequestQueue.release(:mock)
    end
  end

  describe "waiting_count/1" do
    test "counts queued waiters and drops to zero once granted" do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])

      on_exit(fn ->
        Application.delete_env(:ex_athena, :request_queue)
        Application.delete_env(:ex_athena, :mock)
      end)

      assert RequestQueue.waiting_count(:mock) == 0

      :ok = RequestQueue.acquire(:mock)
      test_pid = self()

      task =
        Task.async(fn ->
          RequestQueue.with_slot(:mock, fn -> :ran end,
            timeout: 1_000,
            on_wait: fn status -> send(test_pid, {:wait_status, status}) end
          )
        end)

      # :waiting fires from the waiter just before its acquire call; one
      # bounded poll bridges the remaining enqueue race.
      assert_receive {:wait_status, :waiting}, 500
      assert poll_until(fn -> RequestQueue.waiting_count(:mock) == 1 end)

      RequestQueue.release(:mock)
      assert Task.await(task) == :ran
      assert RequestQueue.waiting_count(:mock) == 0
      RequestQueue.release(:mock)
    end

    defp poll_until(fun, attempts \\ 100)
    defp poll_until(_fun, 0), do: false

    defp poll_until(fun, attempts) do
      if fun.() do
        true
      else
        receive do
        after
          5 -> :ok
        end

        poll_until(fun, attempts - 1)
      end
    end
  end

  describe "dead waiter cleanup" do
    test "a dying waiter is removed from the queue so the next release decrements depth" do
      max = ExAthena.Config.request_queue_max_depth(:ollama)
      for _ <- 1..max, do: :ok = RequestQueue.acquire(:ollama)

      waiter = spawn(fn -> RequestQueue.acquire(:ollama) end)
      Process.sleep(20)

      Process.exit(waiter, :kill)
      Process.sleep(20)

      :ok = RequestQueue.release(:ollama)
      assert RequestQueue.depth(:ollama) == max - 1
    end
  end
end
