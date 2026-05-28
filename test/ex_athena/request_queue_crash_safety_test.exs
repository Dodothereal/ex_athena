defmodule ExAthena.RequestQueueCrashSafetyTest do
  use ExUnit.Case, async: false

  alias ExAthena.RequestQueue

  # A provider that always raises — bypasses Mock's try/rescue so the exception
  # propagates out of the entry point and into the after block.
  defmodule RaisingProvider do
    @behaviour ExAthena.Provider

    def capabilities do
      %{
        native_tool_calls: false,
        streaming: false,
        json_mode: false,
        structured_output: false,
        max_tokens: 1000,
        supports_resume: false,
        supports_system_prompt: false,
        supports_temperature: false
      }
    end

    def query(_req, _opts), do: raise("intentional provider error")
    def stream(_req, _cb, _opts), do: raise("intentional stream error")
    def extract(_req, _opts), do: raise("intentional extract error")
  end

  setup do
    Application.put_env(:ex_athena, :request_queue, enabled: true)
    start_supervised!(RequestQueue)

    on_exit(fn ->
      Application.delete_env(:ex_athena, :request_queue)
    end)
  end

  describe "no permit leak on error" do
    test "slot is released when query returns an error tuple" do
      assert {:error, :some_error} =
               ExAthena.query("hi", provider: :mock, mock: [error: :some_error])

      assert RequestQueue.depth(:mock) == 0
    end

    test "slot is released when query provider raises an exception" do
      assert_raise RuntimeError, "intentional provider error", fn ->
        ExAthena.query("hi", provider: RaisingProvider)
      end

      assert RequestQueue.depth(RaisingProvider) == 0
    end

    test "slot is released when stream callback raises an exception" do
      events = [%ExAthena.Streaming.Event{type: :text_delta, data: "x"}]
      bad_callback = fn _event -> raise "callback crashed" end

      assert_raise RuntimeError, "callback crashed", fn ->
        ExAthena.stream("hi", bad_callback,
          provider: :mock,
          mock: [text: "ok"],
          mock_events: events
        )
      end

      assert RequestQueue.depth(:mock) == 0
    end

    test "slot is released when stream provider raises an exception" do
      assert_raise RuntimeError, "intentional stream error", fn ->
        ExAthena.stream("hi", fn _ -> :ok end, provider: RaisingProvider)
      end

      assert RequestQueue.depth(RaisingProvider) == 0
    end

    test "multiple sequential errors do not accumulate depth" do
      for _ <- 1..5 do
        ExAthena.query("hi", provider: :mock, mock: [error: :err])
      end

      assert RequestQueue.depth(:mock) == 0
    end
  end

  describe "no permit leak on error — run/2" do
    test "slot is released when run provider raises" do
      assert_raise RuntimeError, "intentional provider error", fn ->
        ExAthena.run("hi", provider: RaisingProvider)
      end

      assert RequestQueue.depth(RaisingProvider) == 0
    end
  end

  describe "no permit leak on error — extract_structured/2" do
    test "slot is released when extract_structured provider raises" do
      assert_raise RuntimeError, "intentional provider error", fn ->
        ExAthena.extract_structured("hi", provider: RaisingProvider, schema: %{})
      end

      assert RequestQueue.depth(RaisingProvider) == 0
    end

    test "slot is released when extract_structured returns an error" do
      assert {:error, _} =
               ExAthena.extract_structured("hi",
                 provider: :mock,
                 schema: %{},
                 mock: [error: :extraction_failed],
                 max_retries: 0
               )

      assert RequestQueue.depth(:mock) == 0
    end
  end

  describe "slot released for streaming errors mid-stream" do
    test "depth returns to zero after callback exception regardless of stream position" do
      # Emit two events; callback crashes on the second
      events = [
        %ExAthena.Streaming.Event{type: :text_delta, data: "first"},
        %ExAthena.Streaming.Event{type: :text_delta, data: "second"}
      ]

      call_count = :counters.new(1, [])

      callback = fn _event ->
        :counters.add(call_count, 1, 1)

        if :counters.get(call_count, 1) >= 2 do
          raise "mid-stream crash"
        end
      end

      assert_raise RuntimeError, "mid-stream crash", fn ->
        ExAthena.stream("hi", callback,
          provider: :mock,
          mock: [text: "ok"],
          mock_events: events
        )
      end

      assert RequestQueue.depth(:mock) == 0
    end
  end
end
