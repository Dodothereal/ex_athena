defmodule ExAthena.Chat.SessionTest do
  use ExUnit.Case, async: false

  alias ExAthena.Chat.Session
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}
  alias ExAthena.Result

  setup do
    original = Application.get_env(:ex_athena, :ollama)

    on_exit(fn ->
      if original do
        Application.put_env(:ex_athena, :ollama, original)
      else
        Application.delete_env(:ex_athena, :ollama)
      end
    end)

    :ok
  end

  describe "new/1" do
    test "uses sensible defaults when no overrides are supplied" do
      Application.put_env(:ex_athena, :ollama,
        base_url: "http://localhost:11434",
        model: "llama3.1"
      )

      session = Session.new([])

      assert session.provider == :ollama
      assert session.model == "llama3.1"
      assert session.mode == :react
      assert session.tools == :all
      assert session.permission_mode == :default
      assert session.messages == []
      assert session.iteration == 0
      assert session.usage == %{input_tokens: 0, output_tokens: 0}
      assert session.cost_usd == 0.0
    end

    test "falls back to a placeholder model when none is configured" do
      Application.delete_env(:ex_athena, :ollama)

      session = Session.new([])

      assert session.model == "llama3.1"
    end

    test "accepts overrides via opts" do
      session = Session.new(model: "qwen2.5-coder:14b", mode: :plan_and_solve)

      assert session.model == "qwen2.5-coder:14b"
      assert session.mode == :plan_and_solve
    end
  end

  describe "append_user/2" do
    test "appends a user Message to the history" do
      session = Session.new(model: "m") |> Session.append_user("hello")

      assert [%Message{role: :user, content: "hello"}] = session.messages
    end

    test "preserves earlier messages" do
      session =
        Session.new(model: "m")
        |> Session.append_user("one")
        |> Session.append_user("two")

      assert [
               %Message{role: :user, content: "one"},
               %Message{role: :user, content: "two"}
             ] = session.messages
    end
  end

  describe "clear_messages/1" do
    test "wipes messages but keeps model + mode + counters" do
      session =
        Session.new(model: "m", mode: :reflexion)
        |> Session.append_user("x")
        |> Session.apply_result(%Result{
          iterations: 2,
          usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
          cost_usd: 0.01,
          messages: [Message.__struct__(role: :user, content: "x")]
        })

      cleared = Session.clear_messages(session)

      assert cleared.messages == []
      assert cleared.model == "m"
      assert cleared.mode == :reflexion
      # Counters reset too — a /clear is a "fresh start"
      assert cleared.iteration == 0
      assert cleared.usage == %{input_tokens: 0, output_tokens: 0}
      assert cleared.cost_usd == 0.0
    end
  end

  describe "set_model/2 and set_mode/2" do
    test "set_model/2 swaps the model field, leaves the rest alone" do
      session = Session.new(model: "a") |> Session.append_user("hi")

      updated = Session.set_model(session, "b")

      assert updated.model == "b"
      assert updated.messages == session.messages
    end

    test "set_mode/2 swaps the mode atom" do
      session = Session.new(model: "m")
      assert Session.set_mode(session, :plan_and_solve).mode == :plan_and_solve
    end
  end

  describe "apply_result/2" do
    test "replaces messages with the Result's, sums usage + cost, sets iteration" do
      session = Session.new(model: "m")

      result = %Result{
        messages: [
          %Message{role: :user, content: "hi"},
          %Message{role: :assistant, content: "hello"}
        ],
        usage: %{input_tokens: 12, output_tokens: 7, total_tokens: 19},
        cost_usd: 0.0042,
        iterations: 1
      }

      updated = Session.apply_result(session, result)

      assert length(updated.messages) == 2
      assert updated.usage == %{input_tokens: 12, output_tokens: 7}
      assert updated.cost_usd == 0.0042
      assert updated.iteration == 1
    end

    test "accumulates usage and cost across multiple results" do
      session =
        Session.new(model: "m")
        |> Session.apply_result(%Result{
          messages: [],
          usage: %{input_tokens: 10, output_tokens: 5},
          cost_usd: 0.01,
          iterations: 1
        })
        |> Session.apply_result(%Result{
          messages: [],
          usage: %{input_tokens: 4, output_tokens: 3},
          cost_usd: 0.02,
          iterations: 2
        })

      assert session.usage == %{input_tokens: 14, output_tokens: 8}
      assert_in_delta session.cost_usd, 0.03, 1.0e-9
      # iteration tracks the most recent run's count, not a sum
      assert session.iteration == 2
    end

    test "tolerates nil usage and nil cost from a Result" do
      session = Session.new(model: "m")

      updated =
        Session.apply_result(session, %Result{
          messages: [],
          usage: nil,
          cost_usd: nil,
          iterations: 0
        })

      assert updated.usage == %{input_tokens: 0, output_tokens: 0}
      assert updated.cost_usd == 0.0
    end
  end

  describe "provider session id (resume) tracking" do
    test "apply_result/2 captures the provider session id for resume" do
      session = Session.new(model: "m")

      updated =
        Session.apply_result(session, %Result{messages: [], session_id: "cli-sess-1"})

      assert updated.provider_session_id == "cli-sess-1"
    end

    test "apply_result/2 keeps the previous session id when the result has none" do
      session =
        Session.new(model: "m")
        |> Session.apply_result(%Result{messages: [], session_id: "cli-sess-1"})
        |> Session.apply_result(%Result{messages: [], session_id: nil})

      assert session.provider_session_id == "cli-sess-1"
    end

    test "set_provider/2 clears the session id (it belongs to the old provider)" do
      session =
        Session.new(model: "m")
        |> Session.apply_result(%Result{messages: [], session_id: "cli-sess-1"})
        |> Session.set_provider(:ollama)

      assert session.provider_session_id == nil
    end

    test "clear_messages/1 clears the session id (a /clear is a fresh start)" do
      session =
        Session.new(model: "m")
        |> Session.apply_result(%Result{messages: [], session_id: "cli-sess-1"})
        |> Session.clear_messages()

      assert session.provider_session_id == nil
    end
  end

  describe "tool_results/1" do
    test "extracts ToolResult structs in most-recent-first order" do
      first = %ToolResult{tool_call_id: "1", content: "first", is_error: false}
      second = %ToolResult{tool_call_id: "2", content: "second", is_error: false}

      session = %Session{
        messages: [
          Messages.user("hi"),
          Messages.assistant("calling…", [
            %ToolCall{id: "1", name: "bash", arguments: %{}}
          ]),
          %Message{role: :tool, tool_results: [first]},
          Messages.assistant("again…", [
            %ToolCall{id: "2", name: "read", arguments: %{}}
          ]),
          %Message{role: :tool, tool_results: [second]}
        ]
      }

      assert Session.tool_results(session) == [second, first]
    end

    test "returns an empty list when no tool messages exist" do
      session = %Session{messages: [Messages.user("hi"), Messages.assistant("hello")]}
      assert Session.tool_results(session) == []
    end

    test "skips tool messages whose tool_results field is nil" do
      session = %Session{messages: [%Message{role: :tool, tool_results: nil}]}
      assert Session.tool_results(session) == []
    end
  end
end
