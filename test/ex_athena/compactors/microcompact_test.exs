defmodule ExAthena.Compactors.MicrocompactTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.Microcompact
  alias ExAthena.Loop.State
  alias ExAthena.Messages.{Message, ToolResult}

  defp state_with(messages, opts) do
    %State{
      messages: messages,
      provider_mod: ExAthena.Providers.Mock,
      provider_opts: [],
      request_template: %ExAthena.Request{messages: messages},
      meta: Enum.into(opts, %{})
    }
  end

  defp tool_msg(id, content),
    do: %Message{
      role: :tool,
      tool_results: [%ToolResult{tool_call_id: id, content: content, is_error: false}]
    }

  test "name/0 reports :microcompact" do
    assert Microcompact.name() == :microcompact
  end

  test "skips when there is no run of 3+ adjacent tool messages" do
    messages = [
      tool_msg("c1", "a"),
      %Message{role: :assistant, content: "thoughts"},
      tool_msg("c2", "b")
    ]

    state = state_with(messages, microcompact_run_threshold: 3, pinned_prefix_count: 0)
    assert :skip = Microcompact.compact_stage(state, %{tokens: 10, max_tokens: 1_000})
  end

  test "excerpts a run of 3+ adjacent tool messages IN PLACE (pairing preserved)" do
    long = fn tag -> tag <> "-" <> String.duplicate("x", 500) end

    messages =
      [
        %Message{role: :user, content: "go"},
        tool_msg("c1", long.("alpha")),
        tool_msg("c2", long.("beta")),
        tool_msg("c3", long.("gamma")),
        tool_msg("c4", long.("delta")),
        %Message{role: :assistant, content: "ok"},
        # Live suffix — stays untouched.
        %Message{role: :user, content: "more"},
        %Message{role: :assistant, content: "yep"}
      ]

    state =
      state_with(messages,
        microcompact_run_threshold: 3,
        microcompact_excerpt_chars: 20,
        pinned_prefix_count: 1
      )

    assert {:ok, new_state, new_estimate} =
             Microcompact.compact_stage(state, %{tokens: 1_000, max_tokens: 10_000})

    # Each message in the run is excerpted IN PLACE — collapsing them into
    # one summary used to orphan the parents' tool_call ids (strict
    # servers 400) and re-send the id-less summary as a user message.
    tool_msgs = Enum.filter(new_state.messages, &(&1.role == :tool))
    assert length(tool_msgs) == 4
    assert Enum.map(tool_msgs, fn m -> hd(m.tool_results).tool_call_id end) == ~w(c1 c2 c3 c4)

    [a, _b, c, d] = tool_msgs
    assert hd(a.tool_results).content =~ "[microcompact excerpt] alpha"
    assert hd(c.tool_results).content =~ "[microcompact excerpt] gamma"
    # Live suffix window (last 4 messages) untouched.
    assert hd(d.tool_results).content =~ String.duplicate("x", 500)

    # Token budget went down.
    assert new_estimate.tokens < 1_000
  end
end
