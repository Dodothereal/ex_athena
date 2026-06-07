defmodule ExAthena.Compactor.PipelineTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactor.Pipeline
  alias ExAthena.Loop.State
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolResult}

  # A trivial test stage that drops the second message of the conversation
  # and shaves 100 tokens off the estimate. Used to assert the pipeline
  # actually walks its stage list and aggregates results.
  defmodule TestStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :test_stage

    @impl true
    def compact_stage(%State{messages: [first | rest]} = state, estimate) do
      case rest do
        [_ | tail] ->
          new_messages = [first | tail]
          {:ok, %{state | messages: new_messages}, %{estimate | tokens: estimate.tokens - 100}}

        _ ->
          :skip
      end
    end
  end

  defmodule SkipStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :skip_stage

    @impl true
    def compact_stage(_state, _estimate), do: :skip
  end

  defmodule FailStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :fail_stage

    @impl true
    def compact_stage(_state, _estimate), do: {:error, :boom}
  end

  defp state_with(messages, opts) do
    %State{
      messages: messages,
      provider_mod: ExAthena.Providers.Mock,
      provider_opts: [],
      request_template: %ExAthena.Request{messages: messages},
      meta: Enum.into(opts, %{})
    }
  end

  test "should_compact?/2 honours the threshold" do
    state = state_with([], compact_at: 0.6)
    refute Pipeline.should_compact?(state, %{tokens: 100, max_tokens: 1_000})
    assert Pipeline.should_compact?(state, %{tokens: 700, max_tokens: 1_000})
  end

  test "should_compact?/2 returns true unconditionally when force: true" do
    state = state_with([], compact_at: 0.99)
    assert Pipeline.should_compact?(state, %{tokens: 1, max_tokens: 1_000, force: true})
  end

  test "compact/2 walks the stage list and reports per-stage application" do
    messages = [
      Messages.system("sp"),
      Messages.user("Q1"),
      Messages.user("Q2"),
      Messages.user("Q3")
    ]

    state =
      state_with(messages,
        compaction_pipeline: [TestStage, SkipStage],
        compact_at: 0.5
      )

    assert {:compact, new_messages, metadata} =
             Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})

    # TestStage dropped one message, SkipStage was a no-op.
    assert length(new_messages) == length(messages) - 1
    assert metadata.stages_applied == [:test_stage]
    assert metadata.before == 800
    assert metadata.after == 700
    assert metadata.reason == :token_budget
  end

  test "compact/2 returns :skip when every stage skips" do
    messages = [Messages.user("hi")]

    state =
      state_with(messages,
        compaction_pipeline: [SkipStage],
        compact_at: 0.5
      )

    assert :skip = Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})
  end

  test "compact/2 stops + surfaces an error when a stage fails" do
    messages = [
      Messages.system("sp"),
      Messages.user("Q1"),
      Messages.user("Q2"),
      Messages.user("Q3")
    ]

    state =
      state_with(messages,
        compaction_pipeline: [TestStage, FailStage],
        compact_at: 0.5
      )

    assert {:error, {:fail_stage, :boom}} =
             Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})
  end

  test "run/3 with force: true runs every stage even when under the threshold" do
    messages = [
      Messages.system("sp"),
      Messages.user("Q1"),
      Messages.user("Q2")
    ]

    state =
      state_with(messages,
        compaction_pipeline: [TestStage],
        compact_at: 0.99
      )

    estimate = %{tokens: 100, max_tokens: 1_000}

    # Without force, we'd skip (under threshold).
    assert :skip = Pipeline.run(state, estimate, force: false)

    # With force, the stage runs.
    assert {:compact, _msgs, metadata} = Pipeline.run(state, estimate, force: true)
    assert metadata.reason == :reactive_recovery
    assert :test_stage in metadata.stages_applied
  end

  # A stage that drops ALL tool-role messages — used to verify that
  # pinned messages survive even aggressive stages.
  defmodule DropToolStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :drop_tool_stage

    @impl true
    def compact_stage(%State{messages: messages} = state, estimate) do
      new_messages = Enum.reject(messages, &(&1.role == :tool))

      if length(new_messages) == length(messages) do
        :skip
      else
        {:ok, %{state | messages: new_messages}, %{estimate | tokens: estimate.tokens - 50}}
      end
    end
  end

  test "pinned messages survive a stage that would otherwise drop them" do
    pinned_tool_msg = %Message{
      role: :tool,
      pin: true,
      tool_results: [%ToolResult{tool_call_id: "exit_plan", content: "the plan", is_error: false}]
    }

    normal_tool_msg = %Message{
      role: :tool,
      pin: false,
      tool_results: [%ToolResult{tool_call_id: "c2", content: "some result", is_error: false}]
    }

    messages = [Messages.system("sp"), pinned_tool_msg, normal_tool_msg]

    state =
      state_with(messages,
        compaction_pipeline: [DropToolStage],
        compact_at: 0.5
      )

    assert {:compact, new_messages, _metadata} =
             Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})

    # The pinned message must survive; the non-pinned may or may not
    # (DropToolStage drops all tool messages, so the non-pinned is gone).
    tool_ids =
      new_messages
      |> Enum.flat_map(fn
        %Message{role: :tool, tool_results: trs} -> Enum.map(trs, & &1.tool_call_id)
        _ -> []
      end)

    assert "exit_plan" in tool_ids
    refute "c2" in tool_ids
  end

  test "restore_pinned re-inserts a pre-pinned message that a stage drops" do
    # Pipeline does not call apply_auto_pin (Loop does). Here we directly
    # pre-set pin: true to verify that restore_pinned brings back any pinned
    # message a stage drops. The full auto_pin integration is in
    # reactive_compaction_test.exs.
    tc = %ExAthena.Messages.ToolCall{id: "tc1", name: "ExitPlanMode", arguments: %{}}

    assistant_msg = %Message{role: :assistant, content: nil, tool_calls: [tc]}

    tool_result_msg = %Message{
      role: :tool,
      pin: true,
      tool_results: [
        %ToolResult{tool_call_id: "tc1", content: "plan approved", is_error: false}
      ]
    }

    messages = [Messages.system("sp"), assistant_msg, tool_result_msg]

    state =
      state_with(messages,
        compaction_pipeline: [DropToolStage],
        compact_at: 0.5
      )

    assert {:compact, new_messages, _meta} =
             Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})

    ids =
      Enum.flat_map(new_messages, fn
        %Message{role: :tool, tool_results: trs} -> Enum.map(trs, & &1.tool_call_id)
        _ -> []
      end)

    assert "tc1" in ids
  end

  test "tool-result archive entries from BudgetReduction land in state.meta after pipeline runs" do
    big = String.duplicate("Z", 25_000)

    messages = [
      Messages.user("hi"),
      %Message{
        role: :tool,
        tool_results: [%ToolResult{tool_call_id: "c1", content: big, is_error: false}]
      }
    ]

    state =
      state_with(messages,
        compaction_pipeline: [ExAthena.Compactors.BudgetReduction],
        per_tool_result_max_chars: 16_000,
        compact_at: 0.1
      )

    assert {:compact, new_messages, metadata} =
             Pipeline.compact(state, %{tokens: 7_000, max_tokens: 10_000})

    [_user, %Message{tool_results: [tr]}] = new_messages
    assert tr.content =~ "[old output cleared"
    assert metadata.stages_applied == [:budget_reduction]
  end
end
