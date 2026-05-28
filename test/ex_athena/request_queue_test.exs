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
