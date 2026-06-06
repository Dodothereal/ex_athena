defmodule ExAthena.Orchestrator.AgentInfoTest do
  @moduledoc """
  Pure event reducers for one agent's observable state (functional core of
  the Coordinator — jido-style logic/runtime split).
  """
  use ExUnit.Case, async: true

  alias ExAthena.Orchestrator.AgentInfo
  alias ExAthena.Messages.{ToolCall, ToolResult}

  defp new(attrs \\ %{}), do: AgentInfo.new("agent-1", attrs)

  describe "new/2" do
    test "starts :running with empty collections" do
      info = AgentInfo.new(:main, %{name: "main"})

      assert info.id == :main
      assert info.name == "main"
      assert info.status == :running
      assert info.todos == []
      assert info.conclusions == []
      assert info.iteration == 0
    end

    test "prompt summaries are truncated" do
      info = AgentInfo.new("a", %{prompt_summary: String.duplicate("x", 500)})
      assert String.length(info.prompt_summary) <= 161
    end
  end

  describe "apply_event/2 — activity" do
    test "{:iteration, n} bumps the iteration and resets current_action" do
      info = new() |> AgentInfo.apply_event({:iteration, 3})
      assert info.iteration == 3
      assert info.current_action == "thinking…"
    end

    test "{:tool_call, tc} sets current_action and appends to the transcript tail" do
      tc = %ToolCall{id: "t1", name: "read", arguments: %{"path" => "x"}}
      info = new() |> AgentInfo.apply_event({:tool_call, tc})

      assert info.current_action == "tool: read"
      assert [{:tool_call, text}] = info.transcript_tail
      assert text =~ "read"
    end

    test "{:tool_result, tr} clears current_action" do
      tr = %ToolResult{tool_call_id: "t1", content: "ok", is_error: nil}

      info =
        new()
        |> AgentInfo.apply_event({:tool_call, %ToolCall{id: "t1", name: "read", arguments: %{}}})
        |> AgentInfo.apply_event({:tool_result, tr})

      assert info.current_action == nil
    end

    test "content and thinking accumulate in the bounded transcript tail" do
      info =
        Enum.reduce(1..50, new(), fn i, acc ->
          AgentInfo.apply_event(acc, {:content, "chunk #{i}"})
        end)

      assert length(info.transcript_tail) <= 30
      # Newest entries survive the bound.
      assert {:content, "chunk 50"} = List.last(info.transcript_tail)
    end

    test "{:usage, u} folds token usage" do
      info =
        new()
        |> AgentInfo.apply_event({:usage, %{input_tokens: 10, output_tokens: 5}})
        |> AgentInfo.apply_event({:usage, %{input_tokens: 7, output_tokens: 3}})

      assert info.usage == %{input_tokens: 17, output_tokens: 8}
    end
  end

  describe "apply_event/2 — status machine" do
    test "queue_wait waiting → :waiting_gpu, acquired → :running" do
      info = new() |> AgentInfo.apply_event({:queue_wait, %{provider: :exo, status: :waiting}})
      assert info.status == :waiting_gpu

      info =
        AgentInfo.apply_event(
          info,
          {:queue_wait, %{provider: :exo, status: :acquired, waited_ms: 12}}
        )

      assert info.status == :running
    end

    test "repeated DERIVED conclusions with differing tool calls do NOT flag stalling" do
      # A busy worker yields "ran bash" every turn while each bash differs —
      # that's progress, not a stall (the badge used to flicker STALLED).
      info =
        new()
        |> AgentInfo.apply_event(
          {:tool_call, %ToolCall{id: "a", name: "bash", arguments: %{"command" => "ls web"}}}
        )
        |> AgentInfo.apply_event(
          {:conclusion, %{iteration: 1, text: "ran bash", source: :derived}}
        )
        |> AgentInfo.apply_event(
          {:tool_call,
           %ToolCall{id: "b", name: "bash", arguments: %{"command" => "cat README.md"}}}
        )
        |> AgentInfo.apply_event(
          {:conclusion, %{iteration: 2, text: "ran bash", source: :derived}}
        )

      assert info.status == :running
    end

    test "repeated derived conclusions WITH identical tool calls flag stalling" do
      tc = %ToolCall{id: "a", name: "bash", arguments: %{"command" => "ls web"}}

      info =
        new()
        |> AgentInfo.apply_event({:tool_call, tc})
        |> AgentInfo.apply_event(
          {:conclusion, %{iteration: 1, text: "ran bash", source: :derived}}
        )
        |> AgentInfo.apply_event({:tool_call, %{tc | id: "b"}})
        |> AgentInfo.apply_event(
          {:conclusion, %{iteration: 2, text: "ran bash", source: :derived}}
        )

      assert info.status == :stalling
    end

    test "a repeated identical conclusion flags :stalling; a fresh one recovers" do
      c = %{iteration: 1, text: "still reading the file", source: :stated}

      info =
        new()
        |> AgentInfo.apply_event({:conclusion, c})
        |> AgentInfo.apply_event({:conclusion, %{c | iteration: 2}})

      assert info.status == :stalling

      info =
        AgentInfo.apply_event(
          info,
          {:conclusion, %{iteration: 3, text: "fixed it", source: :stated}}
        )

      assert info.status == :running
    end

    test "conclusions are capped at 50" do
      info =
        Enum.reduce(1..60, new(), fn i, acc ->
          AgentInfo.apply_event(
            acc,
            {:conclusion, %{iteration: i, text: "c#{i}", source: :stated}}
          )
        end)

      assert length(info.conclusions) == 50
      assert List.last(info.conclusions).text == "c60"
    end

    test "a successful close finalizes stale in_progress sub-todos (pending stays pending)" do
      info =
        new()
        |> AgentInfo.set_todos([
          %{"content" => "done step", "status" => "completed"},
          %{"content" => "was mid-flight", "status" => "in_progress"},
          %{"content" => "never started", "status" => "pending"}
        ])
        |> AgentInfo.apply_event({:done, %ExAthena.Result{finish_reason: :stop}})

      assert Enum.map(info.todos, & &1.status) == [:completed, :completed, :pending]
    end

    test "a FAILED close leaves sub-todos untouched (true state)" do
      info =
        new()
        |> AgentInfo.set_todos([%{"content" => "mid-flight", "status" => "in_progress"}])
        |> AgentInfo.apply_event({:done, %ExAthena.Result{finish_reason: :error_max_turns}})

      assert [%{status: :in_progress}] = info.todos
    end

    test "{:done, result} closes the agent by result category" do
      ok = %ExAthena.Result{finish_reason: :stop}
      bad = %ExAthena.Result{finish_reason: :error_no_progress}

      assert AgentInfo.apply_event(new(), {:done, ok}).status == :done
      assert AgentInfo.apply_event(new(), {:done, bad}).status == :failed
    end

    test "terminal statuses are sticky" do
      info = new() |> AgentInfo.apply_event({:done, %ExAthena.Result{finish_reason: :stop}})
      info = AgentInfo.apply_event(info, {:iteration, 9})
      assert info.status == :done
    end

    test "fail/1 marks a non-terminal agent failed but never reopens a done one" do
      assert AgentInfo.fail(new()).status == :failed

      done = new() |> AgentInfo.apply_event({:done, %ExAthena.Result{finish_reason: :stop}})
      assert AgentInfo.fail(done).status == :done
    end
  end

  describe "set_todos/2 — runtime todo ledger" do
    test "assigns stable ids across full rewrites (Claude task-ledger pattern)" do
      info =
        new()
        |> AgentInfo.set_todos([
          %{"content" => "step A", "status" => "in_progress"},
          %{"content" => "step B", "status" => "pending"}
        ])

      [a1, b1] = info.todos

      info =
        AgentInfo.set_todos(info, [
          %{"content" => "step A", "status" => "completed"},
          %{"content" => "step B", "status" => "in_progress"},
          %{"content" => "step C", "status" => "pending"}
        ])

      [a2, b2, c2] = info.todos
      assert a2.id == a1.id
      assert b2.id == b1.id
      assert c2.id not in [a1.id, b1.id]
      assert a2.status == :completed
    end

    test "enforces a single in_progress item (later ones demoted to pending)" do
      info =
        new()
        |> AgentInfo.set_todos([
          %{"content" => "one", "status" => "in_progress"},
          %{"content" => "two", "status" => "in_progress"}
        ])

      assert Enum.count(info.todos, &(&1.status == :in_progress)) == 1
      assert Enum.at(info.todos, 1).status == :pending
    end

    test "complete_todo/2 flips a todo by id (runtime-derived completion)" do
      info =
        new() |> AgentInfo.set_todos([%{"content" => "delegate step", "status" => "in_progress"}])

      [todo] = info.todos

      info = AgentInfo.complete_todo(info, todo.id)
      assert hd(info.todos).status == :completed
    end
  end
end
