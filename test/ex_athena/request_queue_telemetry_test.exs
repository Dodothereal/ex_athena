defmodule ExAthena.RequestQueueTelemetryTest do
  use ExUnit.Case, async: false

  alias ExAthena.RequestQueue

  setup tags do
    test_pid = self()
    handler_id = "rq-telemetry-#{inspect(tags.test)}"

    events = [
      [:ex_athena, :request_queue, :wait],
      [:ex_athena, :request_queue, :acquired],
      [:ex_athena, :request_queue, :released],
      [:ex_athena, :request_queue, :timeout]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, meta, _ ->
        send(test_pid, {:telemetry, name, measurements, meta})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:ex_athena, :request_queue)
      Application.delete_env(:ex_athena, :mock)
    end)
  end

  describe "telemetry with queue enabled" do
    setup do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      start_supervised!(RequestQueue)
      :ok
    end

    test "emits :wait, :acquired, :released on a successful query" do
      assert {:ok, _} = ExAthena.query("hi", provider: :mock, mock: [text: "ok"])

      assert_receive {:telemetry, [:ex_athena, :request_queue, :wait], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :acquired], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :released], _, %{provider: :mock}}
    end

    test "emits :wait, :acquired, :released when query returns an error" do
      assert {:error, :some_error} =
               ExAthena.query("hi", provider: :mock, mock: [error: :some_error])

      assert_receive {:telemetry, [:ex_athena, :request_queue, :wait], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :acquired], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :released], _, %{provider: :mock}}
    end

    test "emits :released even when stream callback raises" do
      events = [%ExAthena.Streaming.Event{type: :text_delta, data: "x"}]
      bad_callback = fn _event -> raise "boom" end

      assert_raise RuntimeError, "boom", fn ->
        ExAthena.stream("hi", bad_callback,
          provider: :mock,
          mock: [text: "ok"],
          mock_events: events
        )
      end

      assert_receive {:telemetry, [:ex_athena, :request_queue, :wait], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :acquired], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :released], _, %{provider: :mock}}
    end

    test "emits :timeout when acquire times out" do
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])
      :ok = RequestQueue.acquire(:mock)

      assert {:error, :request_queue_timeout} =
               ExAthena.query("hi",
                 provider: :mock,
                 mock: [text: "never"],
                 queue_timeout: 20
               )

      assert_receive {:telemetry, [:ex_athena, :request_queue, :wait], _, %{provider: :mock}}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :timeout], _, %{provider: :mock}}
      refute_received {:telemetry, [:ex_athena, :request_queue, :acquired], _, _}
      refute_received {:telemetry, [:ex_athena, :request_queue, :released], _, _}

      RequestQueue.release(:mock)
    end

    test "measurements carry expected fields" do
      assert {:ok, _} = ExAthena.query("hi", provider: :mock, mock: [text: "ok"])

      assert_receive {:telemetry, [:ex_athena, :request_queue, :wait], wait_m, _}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :acquired], acq_m, _}
      assert_receive {:telemetry, [:ex_athena, :request_queue, :released], rel_m, _}

      assert is_map(wait_m)
      assert is_integer(acq_m.wait_ms) and acq_m.wait_ms >= 0
      assert is_integer(acq_m.depth) and acq_m.depth >= 0
      assert is_integer(rel_m.depth) and rel_m.depth >= 0
    end

    test ":timeout measurement carries waited_ms" do
      Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])
      :ok = RequestQueue.acquire(:mock)

      assert {:error, :request_queue_timeout} =
               ExAthena.query("hi",
                 provider: :mock,
                 mock: [text: "never"],
                 queue_timeout: 20
               )

      assert_receive {:telemetry, [:ex_athena, :request_queue, :timeout], timeout_m, _}
      assert is_integer(timeout_m.waited_ms) and timeout_m.waited_ms >= 0

      RequestQueue.release(:mock)
    end
  end

  describe "no telemetry when queue is disabled" do
    test "no request_queue events are emitted when queue is not enabled" do
      assert {:ok, _} = ExAthena.query("hi", provider: :mock, mock: [text: "ok"])

      refute_received {:telemetry, [:ex_athena, :request_queue, _], _, _}
    end

    test "no request_queue events when queue: false is passed" do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      start_supervised!(RequestQueue)

      assert {:ok, _} =
               ExAthena.query("hi", provider: :mock, mock: [text: "ok"], queue: false)

      refute_received {:telemetry, [:ex_athena, :request_queue, _], _, _}
    end
  end
end
