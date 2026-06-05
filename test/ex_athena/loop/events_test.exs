defmodule ExAthena.Loop.EventsTest do
  @moduledoc """
  Tests for Events.provider_stream_callback/1 and /2 — the translator between
  ExAthena.Streaming.Event structs (provider-side) and Loop event tuples
  (host-side).
  """
  use ExUnit.Case, async: true

  alias ExAthena.Loop.Events
  alias ExAthena.Streaming.Event

  # Helper: build a fresh {callback, counters} pair wired to send events to the
  # current test process.
  defp build(opts \\ []) do
    on_event = fn event -> send(self(), {:evt, event}) end
    Events.provider_stream_callback(on_event, opts)
  end

  # 1. text_delta forwards content, increments slot 1 only
  test "text_delta emits {:content, text} and increments text counter" do
    {cb, counters} = build()
    cb.(%Event{type: :text_delta, data: "hel"})

    assert_received {:evt, {:content, "hel"}}
    assert :counters.get(counters, 1) == 1
    assert :counters.get(counters, 2) == 0
  end

  # 2. thinking_delta forwards thinking, increments slot 2 only
  test "thinking_delta emits {:thinking, text} and increments thinking counter" do
    {cb, counters} = build()
    cb.(%Event{type: :thinking_delta, data: "hmm"})

    assert_received {:evt, {:thinking, "hmm"}}
    assert :counters.get(counters, 1) == 0
    assert :counters.get(counters, 2) == 1
  end

  # 3. multiple deltas accumulate correctly
  test "multiple deltas accumulate counts independently" do
    {cb, counters} = build()

    cb.(%Event{type: :text_delta, data: "a"})
    cb.(%Event{type: :text_delta, data: "b"})
    cb.(%Event{type: :text_delta, data: "c"})
    cb.(%Event{type: :thinking_delta, data: "x"})
    cb.(%Event{type: :thinking_delta, data: "y"})

    assert :counters.get(counters, 1) == 3
    assert :counters.get(counters, 2) == 2
  end

  # 4. non-delta events emit nothing and leave counters untouched
  test "usage, stop, start, error, tool_call_start, tool_call_delta emit nothing" do
    {cb, counters} = build()
    ignored_types = [:usage, :stop, :start, :error, :tool_call_start, :tool_call_delta]

    for type <- ignored_types do
      cb.(%Event{type: type, data: %{}})
    end

    refute_received {:evt, _}
    assert :counters.get(counters, 1) == 0
    assert :counters.get(counters, 2) == 0
  end

  # 5. tool_call_end with default opts (forward_tool_events: false) → silent
  test "tool_call_end with default opts emits nothing" do
    {cb, counters} = build()
    cb.(%Event{type: :tool_call_end, data: %{id: "t1", name: "bash"}})

    refute_received {:evt, _}
    assert :counters.get(counters, 1) == 0
    assert :counters.get(counters, 2) == 0
  end

  # 6. tool_call_end with forward_tool_events: true → emits {:tool_call, data}
  test "tool_call_end with forward_tool_events: true emits {:tool_call, data}" do
    {cb, counters} = build(forward_tool_events: true)
    tool_call = %{id: "t1", name: "bash", arguments: %{}}
    cb.(%Event{type: :tool_call_end, data: tool_call})

    assert_received {:evt, {:tool_call, ^tool_call}}
    assert :counters.get(counters, 1) == 0
    assert :counters.get(counters, 2) == 0
  end

  # 7. tool_result with forward_tool_events: true → emits {:tool_result, data}
  test "tool_result with forward_tool_events: true emits {:tool_result, data}" do
    {cb, counters} = build(forward_tool_events: true)
    tool_result = %{tool_call_id: "t1", content: "ok"}
    cb.(%Event{type: :tool_result, data: tool_result})

    assert_received {:evt, {:tool_result, ^tool_result}}
    assert :counters.get(counters, 1) == 0
    assert :counters.get(counters, 2) == 0
  end

  # 8. non-binary text_delta data → nothing emitted, counter untouched
  test "text_delta with non-binary data emits nothing and leaves counters untouched" do
    {cb, counters} = build()
    cb.(%Event{type: :text_delta, data: nil})

    refute_received {:evt, _}
    assert :counters.get(counters, 1) == 0
  end

  # 9. default opts: fences flow through untouched (no filtering)
  test "with default opts text deltas containing fences pass through untouched" do
    {cb, _counters} = build()
    fenced = "~~~tool_call\n{\"name\":\"bash\"}\n~~~"
    cb.(%Event{type: :text_delta, data: fenced})

    assert_received {:evt, {:content, ^fenced}}
  end

  describe "filter_tool_fences: true" do
    test "strips a complete fence from text deltas, emitting only clean text" do
      {cb, counters} = build(filter_tool_fences: true)

      cb.(%Event{type: :text_delta, data: "before\n"})
      cb.(%Event{type: :text_delta, data: "~~~tool_call\n{\"name\":\"bash\"}"})
      cb.(%Event{type: :text_delta, data: "\n~~~\nafter"})

      assert_received {:evt, {:content, "before\n"}}
      assert_received {:evt, {:content, "\nafter"}}
      refute_received {:evt, {:content, _}}

      # Counter tracks every RAW text delta, visible or swallowed, so the
      # end-of-turn full-text suppression stays armed.
      assert :counters.get(counters, 1) == 3
    end

    test "fully-swallowed deltas emit no {:content, \"\"}" do
      {cb, counters} = build(filter_tool_fences: true)
      cb.(%Event{type: :text_delta, data: "~~~tool_call\n{\"name\":"})

      refute_received {:evt, _}
      assert :counters.get(counters, 1) == 1
    end

    test ":stop flushes pending partial-marker text as content" do
      {cb, _counters} = build(filter_tool_fences: true)
      cb.(%Event{type: :text_delta, data: "tail ~~"})
      assert_received {:evt, {:content, "tail "}}

      cb.(%Event{type: :stop, data: :stop})
      assert_received {:evt, {:content, "~~"}}
    end

    test ":stop with an unterminated fence flushes nothing" do
      {cb, _counters} = build(filter_tool_fences: true)
      cb.(%Event{type: :text_delta, data: "~~~tool_call\n{\"name\":\"bash\""})
      cb.(%Event{type: :stop, data: :stop})

      refute_received {:evt, _}
    end

    test "thinking deltas are not filtered" do
      {cb, _counters} = build(filter_tool_fences: true)
      cb.(%Event{type: :thinking_delta, data: "~~~tool_call thoughts"})

      assert_received {:evt, {:thinking, "~~~tool_call thoughts"}}
    end
  end
end
