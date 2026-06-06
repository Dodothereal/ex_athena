defmodule ExAthena.Modes.StreamingTest do
  @moduledoc """
  Verifies that the ReAct mode dispatches to `provider_mod.stream/3` when
  the caller registered an `on_event` callback, translating provider
  `%Streaming.Event{}` deltas into Loop tuples (`{:content, chunk}`,
  `{:thinking, chunk}`) — and that the end-of-turn full-text emission is
  suppressed when deltas already streamed (but kept when they didn't).
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Result}
  alias ExAthena.Streaming.Event

  setup do
    dir = Path.join(System.tmp_dir!(), "stream_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp collecting_on_event do
    test_pid = self()
    fn event -> send(test_pid, {:event, event}) end
  end

  test "forwards provider deltas as {:content, chunk} tuples in order", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "hello world"],
               mock_events: [
                 %Event{type: :text_delta, data: "hel"},
                 %Event{type: :text_delta, data: "lo "},
                 %Event{type: :text_delta, data: "world"}
               ],
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    # assert_receive consumes mailbox messages in order, so binding the
    # chunk (rather than matching a literal) proves delta ordering.
    assert_receive {:event, {:content, chunk1}}
    assert_receive {:event, {:content, chunk2}}
    assert_receive {:event, {:content, chunk3}}
    assert [chunk1, chunk2, chunk3] == ["hel", "lo ", "world"]

    # Raw provider stream events must never leak to the host callback.
    refute_received {:event, %Event{}}
  end

  test "suppresses the end-of-turn full content when text deltas streamed", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "hello world"],
               mock_events: [
                 %Event{type: :text_delta, data: "hel"},
                 %Event{type: :text_delta, data: "lo "},
                 %Event{type: :text_delta, data: "world"}
               ],
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    refute_received {:event, {:content, "hello world"}}
  end

  test "still emits final {:content, full} when the stream produced no deltas", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "hello world"],
               mock_events: [],
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    assert_receive {:event, {:content, "hello world"}}
  end

  test "never emits {:content, \"\"} for a terminal turn with no assistant text", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: ""],
               mock_events: [%Event{type: :thinking_delta, data: "hmm"}],
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    refute_received {:event, {:content, ""}}
  end

  test "never emits {:content, \"\"} for a tool-call-only turn (no assistant text)", %{dir: dir} do
    File.write!(Path.join(dir, "hello.txt"), "hello world")

    responses = [
      %ExAthena.Response{
        text: "",
        tool_calls: [
          %ExAthena.Messages.ToolCall{id: "c1", name: "read", arguments: %{"path" => "hello.txt"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %ExAthena.Response{
        text: "the file says hello",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)
      Enum.at(responses, :counters.get(counter, 1) - 1) || List.last(responses)
    end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("read hello.txt",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               on_event: collecting_on_event()
             )

    refute_received {:event, {:content, ""}}
  end

  test "forwards thinking deltas and suppresses end-of-turn full thinking", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "hello world", thinking: "deep thought"],
               mock_events: [
                 %Event{type: :thinking_delta, data: "deep "},
                 %Event{type: :thinking_delta, data: "thought"},
                 %Event{type: :text_delta, data: "hello world"}
               ],
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    assert_receive {:event, {:thinking, "deep "}}
    assert_receive {:event, {:thinking, "thought"}}
    refute_received {:event, {:thinking, "deep thought"}}
  end

  test "still emits final {:thinking, full} when the stream produced no thinking deltas", %{
    dir: dir
  } do
    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "hello world", thinking: "deep thought"],
               mock_events: [],
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    assert_receive {:event, {:thinking, "deep thought"}}
  end

  test "filters ~~~tool_call fences from streamed text for non-native providers", %{dir: dir} do
    # Non-native providers (TextTagged protocol) emit tool calls as text
    # fences inside the delta stream. The host must only see the clean
    # narrative text; the fence markup must never leak as {:content, _}.
    # Mock declares native_tool_calls: true, so override via the
    # `capabilities:` opt (merged over provider capabilities by the loop).
    events = [
      %Event{type: :text_delta, data: "Let me check.\n"},
      %Event{type: :text_delta, data: "~~~tool"},
      %Event{type: :text_delta, data: "_call\n{\"name\":\"bash\",\"arguments\":{}}"},
      %Event{type: :text_delta, data: "\n~~~"},
      %Event{type: :text_delta, data: "\nDone."}
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "Let me check.\nDone."],
               mock_events: events,
               capabilities: %{native_tool_calls: false},
               cwd: dir,
               tools: [],
               on_event: collecting_on_event()
             )

    chunks = collect_content_chunks()
    assert Enum.join(chunks) == "Let me check.\n\nDone."
    refute Enum.any?(chunks, &(&1 =~ "~~~"))
    refute Enum.any?(chunks, &(&1 =~ "tool_call"))
  end

  defp collect_content_chunks(acc \\ []) do
    receive do
      {:event, {:content, chunk}} -> collect_content_chunks([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "falls back to query/2 when on_event is nil", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop, text: "no stream needed"}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "no stream needed"],
               cwd: dir,
               tools: []
             )
  end
end
