defmodule ExAthena.Providers.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias ExAthena.Providers.ClaudeCode

  test "is registered as the :claude_code provider" do
    assert ExAthena.Config.provider_module(:claude_code) == ClaudeCode
  end

  test "declares self-contained-agent capabilities" do
    caps = ClaudeCode.capabilities()

    # The CLI runs its own tools, so ex_athena must not execute tools for it.
    refute caps.native_tool_calls
    assert caps.streaming
    assert caps.supports_resume
    # claude_code exposes no temperature knob.
    refute caps.supports_temperature
  end

  test "capabilities/1 falls back to the static map" do
    assert ClaudeCode.capabilities(model: "opus") == ClaudeCode.capabilities()
  end

  # The model list is sourced from the claude_code SDK's `supported_models`
  # handshake. We wrap that boundary behind a ModelSource behaviour we own so it
  # can be stubbed here without standing up the real CLI.
  defmodule UnsortedSource do
    @behaviour ExAthena.Providers.ClaudeCode.ModelSource
    @impl true
    def supported_models do
      {:ok,
       [
         %{value: "claude-sonnet-4-6", display_name: "Sonnet 4.6"},
         %{value: "claude-opus-4-8", display_name: "Opus 4.8"},
         # blank values are dropped
         %{value: ""},
         %{value: nil},
         # duplicates are collapsed
         %{value: "claude-opus-4-8", display_name: "Opus 4.8"}
       ]}
    end
  end

  defmodule ErrorSource do
    @behaviour ExAthena.Providers.ClaudeCode.ModelSource
    @impl true
    def supported_models, do: {:error, :unavailable}
  end

  test "list_models/1 returns sorted, unique, non-blank model values from the source" do
    assert ClaudeCode.list_models(UnsortedSource) ==
             {:ok, ["claude-opus-4-8", "claude-sonnet-4-6"]}
  end

  test "list_models/1 propagates source errors" do
    assert ClaudeCode.list_models(ErrorSource) == {:error, :unavailable}
  end

  # ── streaming message handling ───────────────────────────────────
  #
  # handle_message/3 is the pure core of stream/3: it maps SDK messages to
  # canonical Streaming events. We drive it directly with constructed SDK
  # structs so no CLI process is needed.

  describe "handle_message/3" do
    # The provider module is aliased as `ClaudeCode` above, so the SDK modules
    # must be referenced from the root (`Elixir.`) to avoid expanding to
    # `ExAthena.Providers.ClaudeCode.Content.*`.
    alias Elixir.ClaudeCode.Content.{TextBlock, ThinkingBlock, ToolResultBlock, ToolUseBlock}
    alias Elixir.ClaudeCode.Message.{AssistantMessage, PartialAssistantMessage, UserMessage}
    alias ExAthena.Messages.{ToolCall, ToolResult}
    alias ExAthena.Streaming

    defp collector do
      parent = self()
      fn ev -> send(parent, {:ev, ev}) end
    end

    defp acc(overrides \\ []) do
      Enum.into(overrides, %{result: nil, thinking: [], partials?: false})
    end

    defp partial!(event_json) do
      {:ok, partial} =
        PartialAssistantMessage.new(%{
          "type" => "stream_event",
          "event" => event_json,
          "session_id" => "sess"
        })

      partial
    end

    defp assistant_message(content) do
      %AssistantMessage{
        type: :assistant,
        message: %{role: :assistant, content: content},
        session_id: "sess"
      }
    end

    defp user_message(content) do
      %UserMessage{
        type: :user,
        message: %{role: :user, content: content},
        session_id: "sess"
      }
    end

    test "partial text delta emits :text_delta and sets partials?" do
      partial =
        partial!(%{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "chunk"}
        })

      acc = ClaudeCode.handle_message(partial, collector(), acc())

      assert_receive {:ev, %Streaming.Event{type: :text_delta, data: "chunk"}}
      assert acc.partials?
      assert acc.thinking == []
    end

    test "partial thinking delta emits :thinking_delta, accumulates, and sets partials?" do
      partial =
        partial!(%{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "hmm"}
        })

      acc = ClaudeCode.handle_message(partial, collector(), acc())

      assert_receive {:ev, %Streaming.Event{type: :thinking_delta, data: "hmm"}}
      assert acc.partials?
      assert acc.thinking == ["hmm"]
    end

    test "non-delta partial (content_block_stop) emits nothing and leaves acc unchanged" do
      partial = partial!(%{"type" => "content_block_stop", "index" => 0})

      acc = ClaudeCode.handle_message(partial, collector(), acc())

      refute_received {:ev, _}
      assert acc == acc([])
    end

    test "full AssistantMessage with partials?: false emits per-block text/thinking (fallback)" do
      message =
        assistant_message([
          %ThinkingBlock{type: :thinking, thinking: "deep thought", signature: "sig"},
          %TextBlock{type: :text, text: "hello"}
        ])

      acc = ClaudeCode.handle_message(message, collector(), acc())

      assert_receive {:ev, %Streaming.Event{type: :thinking_delta, data: "deep thought"}}
      assert_receive {:ev, %Streaming.Event{type: :text_delta, data: "hello"}}
      assert acc.thinking == ["deep thought"]
    end

    test "full AssistantMessage with partials?: true emits no text/thinking and accumulates nothing" do
      message =
        assistant_message([
          %ThinkingBlock{type: :thinking, thinking: "deep thought", signature: "sig"},
          %TextBlock{type: :text, text: "hello"}
        ])

      acc = ClaudeCode.handle_message(message, collector(), acc(partials?: true))

      refute_received {:ev, _}
      assert acc.thinking == []
    end

    test "ToolUseBlock emits :tool_call_end with a real ToolCall even when partials?: true" do
      message =
        assistant_message([
          %ToolUseBlock{type: :tool_use, id: "tu_1", name: "Read", input: %{"path" => "x.ex"}}
        ])

      ClaudeCode.handle_message(message, collector(), acc(partials?: true))

      assert_receive {:ev, %Streaming.Event{type: :tool_call_end, data: tool_call}}
      assert %ToolCall{id: "tu_1", name: "Read", arguments: %{"path" => "x.ex"}} = tool_call
    end

    test "UserMessage ToolResultBlock with string content emits :tool_result" do
      message =
        user_message([
          %ToolResultBlock{
            type: :tool_result,
            tool_use_id: "tu_1",
            content: "ok",
            is_error: false
          }
        ])

      acc = ClaudeCode.handle_message(message, collector(), acc())

      assert_receive {:ev, %Streaming.Event{type: :tool_result, data: tool_result}}
      assert %ToolResult{tool_call_id: "tu_1", content: "ok", is_error: false} = tool_result
      assert acc == acc([])
    end

    test "UserMessage ToolResultBlock with [TextBlock] content flattens to joined text" do
      message =
        user_message([
          %ToolResultBlock{
            type: :tool_result,
            tool_use_id: "tu_2",
            content: [
              %TextBlock{type: :text, text: "line 1"},
              %TextBlock{type: :text, text: "line 2"}
            ],
            is_error: true
          }
        ])

      ClaudeCode.handle_message(message, collector(), acc())

      assert_receive {:ev, %Streaming.Event{type: :tool_result, data: tool_result}}

      assert %ToolResult{tool_call_id: "tu_2", content: "line 1line 2", is_error: true} =
               tool_result
    end
  end

  describe "stream_opts/2" do
    alias ExAthena.Request

    defp request(provider_opts \\ nil) do
      %Request{messages: [], model: "claude-opus-4-8", provider_opts: provider_opts}
    end

    test "enables include_partial_messages by default" do
      opts = ClaudeCode.stream_opts(request(), [])
      assert opts[:include_partial_messages] == true
    end

    test "respects a caller opt-out via provider_opts" do
      opts = ClaudeCode.stream_opts(request(include_partial_messages: false), [])
      assert opts[:include_partial_messages] == false
    end

    test "build_opts/2 (used by query/2) does not set include_partial_messages" do
      opts = ClaudeCode.build_opts(request(), [])
      refute Keyword.has_key?(opts, :include_partial_messages)
    end
  end

  describe "Streaming.tool_result/2" do
    alias ExAthena.Messages.ToolResult
    alias ExAthena.Streaming

    test "emits a :tool_result event carrying the ToolResult" do
      parent = self()
      cb = fn ev -> send(parent, {:ev, ev}) end
      tr = %ToolResult{tool_call_id: "tu_1", content: "ok", is_error: false}

      assert :ok = Streaming.tool_result(cb, tr)
      assert_receive {:ev, %Streaming.Event{type: :tool_result, data: ^tr}}
    end
  end
end
