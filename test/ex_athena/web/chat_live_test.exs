defmodule ExAthena.Web.Live.ChatLiveTest do
  use ExUnit.Case, async: true

  alias ExAthena.Orchestrator.AgentInfo
  alias ExAthena.Result
  alias ExAthena.Web.Live.ChatLive

  describe "maybe_surface_deliverable/4 — showing the finish answer in chat" do
    test "prepends the deliverable as an assistant-text item when not streamed" do
      result = %Result{finish_reason: :submitted, deliverable: "the final answer"}

      assert [entry | []] = ChatLive.maybe_surface_deliverable([], "m1", "", result)
      assert entry.type == :assistant_text
      assert entry.message_id == "m1"
      assert entry.payload == %{text: "the final answer"}
    end

    test "appears as the newest entry (rendered last, after tool rows)" do
      existing = [%{type: :tool_call, message_id: "m1", payload: %{}}]
      result = %Result{finish_reason: :submitted, deliverable: "answer"}

      assert [newest | rest] = ChatLive.maybe_surface_deliverable(existing, "m1", "", result)
      assert newest.type == :assistant_text
      assert rest == existing
    end

    test "is a no-op when the deliverable was already streamed as prose" do
      result = %Result{finish_reason: :submitted, deliverable: "answer"}
      assert ChatLive.maybe_surface_deliverable([], "m1", "here is the answer", result) == []
    end

    test "is a no-op when an assistant-text entry already contains it" do
      stream = [%{type: :assistant_text, message_id: "m1", payload: %{text: "the answer here"}}]
      result = %Result{finish_reason: :submitted, deliverable: "answer"}
      assert ChatLive.maybe_surface_deliverable(stream, "m1", "", result) == stream
    end

    test "is a no-op for non-submitted runs or a blank deliverable" do
      assert ChatLive.maybe_surface_deliverable([], "m1", "", %Result{finish_reason: :stop}) == []

      assert ChatLive.maybe_surface_deliverable(
               [],
               "m1",
               "",
               %Result{finish_reason: :submitted, deliverable: nil}
             ) == []
    end
  end

  describe "orphan_agents/1 — top-level workers not linked to a todo" do
    test "treats an agent with a nil linked_todo as an orphan (no crash)" do
      orchestrator = %{
        main: %{todos: [%{content: "task A"}]},
        agents: [%AgentInfo{id: "a1", parent_id: :main, linked_todo: nil}]
      }

      assert [%AgentInfo{id: "a1"}] = ChatLive.orphan_agents(orchestrator)
    end

    test "excludes agents whose linked_todo matches an existing todo" do
      orchestrator = %{
        main: %{todos: [%{content: "task A"}]},
        agents: [
          %AgentInfo{id: "linked", parent_id: :main, linked_todo: "task A"},
          %AgentInfo{id: "stale", parent_id: :main, linked_todo: "gone"}
        ]
      }

      assert [%AgentInfo{id: "stale"}] = ChatLive.orphan_agents(orchestrator)
    end

    test "excludes nested agents (parent_id is not :main)" do
      orchestrator = %{
        main: %{todos: []},
        agents: [%AgentInfo{id: "child", parent_id: "a1", linked_todo: nil}]
      }

      assert ChatLive.orphan_agents(orchestrator) == []
    end
  end

  describe "model picker selection (handle_event)" do
    defp picker_socket(overrides) do
      assigns =
        Map.merge(
          %{__changed__: %{}, model: "bge-m3:latest", model_query: "", model_open: true},
          Map.new(overrides)
        )

      %Phoenix.LiveView.Socket{assigns: assigns}
    end

    test "closing the dropdown commits a free-typed model name" do
      socket = picker_socket(model_query: "glm-5.2-cloud")

      assert {:noreply, socket} = ChatLive.handle_event("close_models", %{}, socket)
      assert socket.assigns.model == "glm-5.2-cloud"
      assert socket.assigns.model_query == ""
      assert socket.assigns.model_open == false
    end

    test "closing with a blank query keeps the current model" do
      socket = picker_socket(model_query: "   ")

      assert {:noreply, socket} = ChatLive.handle_event("close_models", %{}, socket)
      assert socket.assigns.model == "bge-m3:latest"
      assert socket.assigns.model_open == false
    end

    test "Enter/submit commits the typed value" do
      socket = picker_socket(model_query: "gpt-oss:120b-cloud")

      assert {:noreply, socket} =
               ChatLive.handle_event("set_model", %{"value" => "gpt-oss:120b-cloud"}, socket)

      assert socket.assigns.model == "gpt-oss:120b-cloud"
      assert socket.assigns.model_open == false
    end

    test "clicking an option commits that model" do
      socket = picker_socket(model_query: "gl")

      assert {:noreply, socket} =
               ChatLive.handle_event("set_model", %{"model" => "glm-5.2-cloud"}, socket)

      assert socket.assigns.model == "glm-5.2-cloud"
    end

    test "set_model ignores a blank value (never wipes the current model)" do
      socket = picker_socket(model: "llama3.1")

      assert {:noreply, socket} = ChatLive.handle_event("set_model", %{"value" => "  "}, socket)
      assert socket.assigns.model == "llama3.1"
    end
  end

  describe "filter_models/2 — model search box" do
    @models [
      "mlx-community/Qwen3.5-9B-4bit",
      "mlx-community/Qwen3.6-27B-4bit",
      "mlx-community/gemma-4-e4b-it-4bit",
      "anthropic/claude-3.5-sonnet"
    ]

    test "case-insensitive substring match (anywhere in the id)" do
      assert ChatLive.filter_models(@models, "qwen3.5") == ["mlx-community/Qwen3.5-9B-4bit"]
      # matches the part after the slash, which datalist prefix-matching misses
      assert ChatLive.filter_models(@models, "sonnet") == ["anthropic/claude-3.5-sonnet"]
      assert "mlx-community/gemma-4-e4b-it-4bit" in ChatLive.filter_models(@models, "GEMMA")
    end

    test "blank query returns all (capped); no match returns []" do
      assert ChatLive.filter_models(@models, "") == @models
      assert ChatLive.filter_models(@models, "   ") == @models
      assert ChatLive.filter_models(@models, "nope") == []
    end

    test "caps the result count" do
      many = for i <- 1..200, do: "openrouter/model-#{i}"
      assert length(ChatLive.filter_models(many, "model")) == 60
    end
  end
end
