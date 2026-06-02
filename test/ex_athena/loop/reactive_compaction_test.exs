defmodule ExAthena.Loop.ReactiveCompactionTest do
  @moduledoc """
  PR2 — verifies the kernel's reactive recovery path: a mode that returns
  `{:error, :error_prompt_too_long}` triggers a forced pipeline pass and
  retries the same iteration once.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Loop.State
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  # Stub mode whose first call returns `{:error, :error_prompt_too_long}`
  # and whose second call (after recovery) halts cleanly.
  defmodule FlakyMode do
    @behaviour ExAthena.Loop.Mode

    @impl true
    def init(state) do
      counter = :counters.new(1, [:atomics])
      {:ok, %{state | mode_state: %{counter: counter}}}
    end

    @impl true
    def iterate(%State{mode_state: %{counter: counter}} = state) do
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> {:error, :error_prompt_too_long}
        _ -> {:halt, set_finish(state, :stop)}
      end
    end

    defp set_finish(state, reason), do: put_in(state.meta[:finish_reason], reason)
  end

  # Recovery-disabled stub mode — same as FlakyMode but the kernel
  # should immediately classify as `:error_prompt_too_long` since
  # `:reactive_compact` is set to false.
  defmodule AlwaysOverflowMode do
    @behaviour ExAthena.Loop.Mode
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def iterate(_state), do: {:error, :error_prompt_too_long}
  end

  test "reactive recovery retries the iteration once after forcing the pipeline" do
    responder = fn _req ->
      %Response{text: "ok", finish_reason: :stop, provider: :mock}
    end

    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: :mock,
        mock: [responder: responder],
        tools: [],
        mode: FlakyMode,
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :stop
  end

  # A compactor spy that captures the messages it receives during
  # force_compact and stores them in a process dictionary so the test
  # can inspect them after the loop finishes.
  defmodule SpyCompactor do
    @behaviour ExAthena.Compactor

    @impl true
    def should_compact?(_state, _estimate), do: false

    @impl true
    def compact(%State{messages: messages}, _estimate) do
      Process.put(:spy_messages, messages)
      # Return the messages with a modest token reduction so the loop accepts it.
      {:compact, messages, %{before: 1000, after: 500, dropped_count: 0, reason: :token_budget}}
    end
  end

  defmodule FlakyModeWithSpy do
    @behaviour ExAthena.Loop.Mode

    @impl true
    def init(state) do
      counter = :counters.new(1, [:atomics])
      {:ok, %{state | mode_state: %{counter: counter}}}
    end

    @impl true
    def iterate(%State{mode_state: %{counter: counter}} = state) do
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> {:error, :error_prompt_too_long}
        _ -> {:halt, put_in(state.meta[:finish_reason], :stop)}
      end
    end
  end

  test "auto_pin stamps pin: true on matching tool-result messages before force_compact" do
    tc = %ToolCall{id: "tc_exit", name: "ExitPlanMode", arguments: %{}}

    exit_plan_tool_result = %Message{
      role: :tool,
      pin: false,
      tool_results: [
        %ToolResult{tool_call_id: "tc_exit", content: "the plan text", is_error: false}
      ]
    }

    initial_messages = [
      %Message{role: :assistant, content: nil, tool_calls: [tc]},
      exit_plan_tool_result
    ]

    {:ok, %Result{}} =
      Loop.run("hi",
        provider: :mock,
        mock: [
          responder: fn _req ->
            %Response{text: "ok", finish_reason: :stop, provider: :mock}
          end
        ],
        tools: [],
        mode: FlakyModeWithSpy,
        memory: false,
        skills: %{},
        messages: initial_messages,
        compactor: SpyCompactor,
        auto_pin: %{tool_names: ["ExitPlanMode"]}
      )

    spy_msgs = Process.get(:spy_messages)
    assert spy_msgs != nil, "SpyCompactor was never called"

    pinned_ids =
      spy_msgs
      |> Enum.flat_map(fn
        %Message{role: :tool, pin: true, tool_results: trs} -> Enum.map(trs, & &1.tool_call_id)
        _ -> []
      end)

    assert "tc_exit" in pinned_ids,
           "Expected ExitPlanMode tool-result to be pinned before compaction"

    # The paired assistant message must also be pinned so Summary cannot
    # summarise it away, which would leave an orphaned tool_result.
    assert Enum.any?(spy_msgs, fn
             %Message{role: :assistant, pin: true, tool_calls: tcs} when is_list(tcs) ->
               Enum.any?(tcs, fn tc -> tc.id == "tc_exit" end)

             _ ->
               false
           end),
           "Expected paired assistant message to also be pinned before compaction"
  end

  test "auto_pin does not pin a tool result whose tool_call_id has no paired assistant message" do
    # Simulates a tool result from an already-compacted assistant message:
    # id_to_name won't contain the id, so the result must remain un-pinned (no crash).
    orphan_tool_result = %Message{
      role: :tool,
      pin: false,
      tool_results: [%ToolResult{tool_call_id: "orphan_id", content: "result", is_error: false}]
    }

    {:ok, %Result{}} =
      Loop.run("hi",
        provider: :mock,
        mock: [
          responder: fn _req ->
            %Response{text: "ok", finish_reason: :stop, provider: :mock}
          end
        ],
        tools: [],
        mode: FlakyModeWithSpy,
        memory: false,
        skills: %{},
        messages: [orphan_tool_result],
        compactor: SpyCompactor,
        auto_pin: %{tool_names: ["ExitPlanMode"]}
      )

    spy_msgs = Process.get(:spy_messages)
    assert spy_msgs != nil, "SpyCompactor was never called"

    pinned_ids =
      Enum.flat_map(spy_msgs, fn
        %Message{role: :tool, pin: true, tool_results: trs} -> Enum.map(trs, & &1.tool_call_id)
        _ -> []
      end)

    refute "orphan_id" in pinned_ids,
           "Orphaned tool result (no paired assistant) must not be pinned"
  end

  test "auto_pin pins the whole message when only one of multiple tool_results matches" do
    tc_exit = %ToolCall{id: "tc_exit", name: "ExitPlanMode", arguments: %{}}
    tc_other = %ToolCall{id: "tc_other", name: "SomeTool", arguments: %{}}

    # One :tool message containing two results — only tc_exit matches the auto_pin rule.
    mixed_tool_msg = %Message{
      role: :tool,
      pin: false,
      tool_results: [
        %ToolResult{tool_call_id: "tc_exit", content: "plan text", is_error: false},
        %ToolResult{tool_call_id: "tc_other", content: "other result", is_error: false}
      ]
    }

    initial_messages = [
      %Message{role: :assistant, content: nil, tool_calls: [tc_exit, tc_other]},
      mixed_tool_msg
    ]

    {:ok, %Result{}} =
      Loop.run("hi",
        provider: :mock,
        mock: [
          responder: fn _req ->
            %Response{text: "ok", finish_reason: :stop, provider: :mock}
          end
        ],
        tools: [],
        mode: FlakyModeWithSpy,
        memory: false,
        skills: %{},
        messages: initial_messages,
        compactor: SpyCompactor,
        auto_pin: %{tool_names: ["ExitPlanMode"]}
      )

    spy_msgs = Process.get(:spy_messages)
    assert spy_msgs != nil, "SpyCompactor was never called"

    mixed_pinned? =
      Enum.any?(spy_msgs, fn
        %Message{role: :tool, pin: true, tool_results: trs} ->
          ids = Enum.map(trs, & &1.tool_call_id)
          "tc_exit" in ids and "tc_other" in ids

        _ ->
          false
      end)

    assert mixed_pinned?,
           "Expected the multi-result tool message to be pinned when any result matches"
  end

  # Stateful provider: the first `query/2` reports a context-length overflow
  # (as req_llm does for an HTTP 413), the second — after the kernel has
  # force-compacted the existing context and retried — succeeds. Proves the
  # default ReAct mode translates the provider's `:context_length_exceeded`
  # error into the `:error_prompt_too_long` recovery signal.
  defmodule OverflowThenRecoverProvider do
    @behaviour ExAthena.Provider

    alias ExAthena.{Error, Response}

    @impl true
    def capabilities, do: %{native_tool_calls: true, streaming: false, max_tokens: 128_000}

    @impl true
    def query(_request, opts) do
      counter = Keyword.fetch!(opts, :counter)
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          {:error,
           %Error{
             kind: :context_length_exceeded,
             message: "context length exceeded",
             provider: :test
           }}

        _ ->
          {:ok,
           %Response{text: "recovered after compaction", finish_reason: :stop, provider: :test}}
      end
    end
  end

  test "ReAct recovers from a provider context-length error by compacting the existing context and retrying" do
    counter = :counters.new(1, [:atomics])

    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: OverflowThenRecoverProvider,
        counter: counter,
        tools: [],
        mode: ExAthena.Modes.ReAct,
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :stop
    assert result.text == "recovered after compaction"

    assert :counters.get(counter, 1) == 2,
           "expected the provider to be retried once after compacting the existing context"
  end

  test "PlanAndSolve recovers from a context-length error during the planning phase" do
    counter = :counters.new(1, [:atomics])

    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: OverflowThenRecoverProvider,
        counter: counter,
        tools: [],
        mode: ExAthena.Modes.PlanAndSolve,
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :stop

    assert :counters.get(counter, 1) >= 2,
           "expected the planning call to be retried after compacting the existing context"
  end

  test "with reactive compaction disabled, prompt-too-long terminates immediately" do
    responder = fn _req ->
      %Response{text: "x", finish_reason: :stop, provider: :mock}
    end

    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: :mock,
        mock: [responder: responder],
        tools: [],
        mode: AlwaysOverflowMode,
        reactive_compact: false,
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :error_prompt_too_long
    assert Result.category(result) == :capacity
  end
end
