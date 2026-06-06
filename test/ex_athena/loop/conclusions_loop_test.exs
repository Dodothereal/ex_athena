defmodule ExAthena.Loop.ConclusionsLoopTest do
  @moduledoc """
  Per-iteration `{:conclusion, …}` events, the CONCLUSION prompt contract,
  the Manus-style ledger recitation, and the tightened productivity signal.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "concl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp collector do
    test_pid = self()
    fn event -> send(test_pid, {:event, event}) end
  end

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      resp = Enum.at(responses, n - 1) || List.last(responses)
      if is_function(resp), do: resp.(n), else: resp
    end
  end

  test "every iteration emits a {:conclusion, ...} event", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")

    responses = [
      %Response{
        text: "Looking at the file.\nCONCLUSION: need to read f.txt first.",
        tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "All done.\n\nCONCLUSION: the file contains x.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               on_event: collector()
             )

    assert_receive {:event,
                    {:conclusion,
                     %{iteration: 0, text: "need to read f.txt first.", source: :stated}}}

    assert_receive {:event,
                    {:conclusion, %{iteration: 1, text: "the file contains x.", source: :stated}}}
  end

  test "a tool-call turn without a marker derives its conclusion", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")

    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    Loop.run("go",
      provider: :mock,
      mock: [responder: scripted(responses)],
      cwd: dir,
      tools: [ExAthena.Tools.Read],
      on_event: collector()
    )

    assert_receive {:event, {:conclusion, %{iteration: 0, source: :derived, text: text}}}
    assert text =~ "read"
  end

  test "the CONCLUSION contract is appended to the system prompt by default", %{dir: dir} do
    test_pid = self()

    responder = fn request ->
      send(test_pid, {:system_prompt, request.system_prompt})
      %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    Loop.run("hi", provider: :mock, mock: [responder: responder], cwd: dir, tools: [])

    assert_receive {:system_prompt, sp}
    assert sp =~ "CONCLUSION:"
  end

  test "conclusions: false disables both the contract and the events", %{dir: dir} do
    test_pid = self()

    responder = fn request ->
      send(test_pid, {:system_prompt, request.system_prompt})
      %Response{text: "plain answer", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    Loop.run("hi",
      provider: :mock,
      mock: [responder: responder],
      cwd: dir,
      tools: [],
      conclusions: false,
      on_event: collector()
    )

    assert_receive {:system_prompt, sp}
    refute (sp || "") =~ "CONCLUSION:"
    refute_received {:event, {:conclusion, _}}
  end

  test "the rolling ledger is recited at the request tail but never persisted", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    responder = fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:request_messages, n, request.messages})

      case n do
        1 ->
          %Response{
            text: "CONCLUSION: step one done.",
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    # First request: no ledger yet.
    assert_receive {:request_messages, 1, msgs1}
    refute Enum.any?(msgs1, &ledger_message?/1)

    # Second request: the only ledger entry is the PREVIOUS turn's conclusion,
    # which is already the most recent assistant message in context — reciting
    # it would invite recency-bias parroting (a stale "waiting for input"
    # conclusion made the model claim it was still waiting). So no recitation.
    assert_receive {:request_messages, 2, msgs2}
    refute Enum.any?(msgs2, &ledger_message?/1)

    # The recitation is ephemeral — it never lands in the persisted transcript.
    refute Enum.any?(result.messages, &ledger_message?/1)
  end

  test "the recitation carries older conclusions but never the previous turn's", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    responder = fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:request_messages, n, request.messages})

      if n <= 2 do
        %Response{
          text: "CONCLUSION: step #{n} done.",
          tool_calls: [
            %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "f#{n}.txt"}}
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    Loop.run("go",
      provider: :mock,
      mock: [responder: responder],
      cwd: dir,
      tools: [ExAthena.Tools.Read]
    )

    assert_receive {:request_messages, 3, msgs3}
    ledger = Enum.find(msgs3, &ledger_message?/1)
    assert ledger
    assert message_text(ledger) =~ "step 1 done."
    refute message_text(ledger) =~ "step 2 done."
  end

  test "blank or repeated text no longer counts as productivity", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")

    # Same tool fingerprint + blank text every turn → no-progress trips at 3.
    looping = fn _n ->
      %Response{
        text: " ",
        tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end

    assert {:ok, %Result{finish_reason: :error_no_progress}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted([looping])],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )
  end

  test "identical repeated text with identical tool calls is unproductive", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")

    looping = fn _n ->
      %Response{
        text: "Still investigating the file.",
        tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end

    assert {:ok, %Result{finish_reason: :error_no_progress}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted([looping])],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )
  end

  test "a stalled ledger recites a corrective instruction instead of just repeating itself",
       %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    # Three identical exploratory turns (no marker → derived "ran read"),
    # then a terminal turn. The 3rd+ request's recitation must escalate.
    responder = fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:request, n, request.messages})

      if n <= 3 do
        %Response{
          text: " ",
          tool_calls: [
            %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "f#{n}.txt"}}
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    Loop.run("go",
      provider: :mock,
      mock: [responder: responder],
      cwd: dir,
      tools: [ExAthena.Tools.Read]
    )

    # Request 3 follows two identical derived conclusions → corrective text.
    assert_receive {:request, 3, msgs}
    ledger = Enum.find(msgs, &ledger_message?/1)
    assert ledger
    assert message_text(ledger) =~ "change strategy"

    # Request 2 follows a single conclusion → plain recitation, no nagging.
    assert_receive {:request, 2, msgs2}
    ledger2 = Enum.find(msgs2, &ledger_message?/1)
    refute message_text(ledger2) =~ "change strategy"
  end

  defp ledger_message?(%{content: content}) when is_binary(content),
    do: content =~ "[progress ledger"

  defp ledger_message?(_), do: false

  defp message_text(%{content: content}) when is_binary(content), do: content
  defp message_text(_), do: ""
end
