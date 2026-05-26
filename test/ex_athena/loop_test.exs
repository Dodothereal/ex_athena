defmodule ExAthena.LoopTest do
  @moduledoc """
  End-to-end tests for the agent loop driven by the Mock provider.

  We script the Mock provider to return a sequence of responses, one per call.
  The responder function reads a per-test counter from the process dictionary.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  defmodule CapabilitiesV1Provider do
    @behaviour ExAthena.Provider

    def capabilities do
      %{
        native_tool_calls: true,
        streaming: false,
        json_mode: false,
        structured_output: false,
        max_tokens: 500
      }
    end

    def capabilities(opts) do
      parent = Process.get(:caps1_test_parent)
      if parent, do: send(parent, {:caps1_called, opts})
      %{capabilities() | max_tokens: 99_999}
    end

    def query(_request, _opts) do
      {:ok,
       %ExAthena.Response{
         text: "caps1 response",
         tool_calls: [],
         finish_reason: :stop,
         provider: :caps_v1
       }}
    end
  end

  defp script(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      Enum.at(responses, n - 1) || List.last(responses)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "plain text response: loop terminates in one iteration", %{dir: dir} do
    responses = [
      %Response{text: "no tools needed", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    assert {:ok, result} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               tools: []
             )

    assert result.text == "no tools needed"
    assert result.iterations == 0
  end

  test "model calls a tool, gets a result, then emits text", %{dir: dir} do
    File.write!(Path.join(dir, "hello.txt"), "hello world")

    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "hello.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "The file contains 'hello world'.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    assert {:ok, result} =
             Loop.run("read hello.txt",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    assert result.text =~ "hello world"
    assert result.iterations == 1

    # Messages include: assistant-tool-call, tool-result, assistant-final
    assert Enum.any?(result.messages, &match?(%{role: :tool}, &1))
    assert Enum.any?(result.messages, fn m -> m.role == :assistant and m.tool_calls != nil end)
  end

  test "max_iterations is enforced", %{dir: dir} do
    # Responder that always calls a tool — infinite loop if not capped
    loop_response = %Response{
      text: "",
      tool_calls: [
        %ToolCall{
          id: "c#{System.unique_integer([:positive])}",
          name: "glob",
          arguments: %{"pattern" => "**"}
        }
      ],
      finish_reason: :tool_calls,
      provider: :mock
    }

    responder = fn _req -> loop_response end

    assert {:ok, %ExAthena.Result{finish_reason: :error_max_turns, iterations: 3}} =
             Loop.run("spin",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Glob],
               max_iterations: 3
             )
  end

  test "permission denial returns tool_result with error, loop continues", %{dir: dir} do
    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "bash", arguments: %{"command" => "rm -rf /"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "I can't run shell commands in this mode.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    assert {:ok, result} =
             Loop.run("run bash",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.Bash],
               disallowed_tools: ["bash"]
             )

    assert result.text =~ "can't run"

    # The tool message is a tool-result with is_error: true
    tool_msg = Enum.find(result.messages, &match?(%{role: :tool}, &1))
    assert [%{content: content, is_error: true}] = tool_msg.tool_results
    assert content =~ "disallowed"
  end

  test "unknown tool returns an error message in the loop", %{dir: dir} do
    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "nonexistent_tool", arguments: %{}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    assert {:ok, result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    tool_msg = Enum.find(result.messages, &match?(%{role: :tool}, &1))
    assert [%{is_error: true, content: content}] = tool_msg.tool_results
    assert content =~ "unknown tool"
    assert content =~ "nonexistent_tool"
  end

  test "capabilities: %{native_tool_calls: false} injects ~~~tool_call preamble into system prompt",
       %{dir: dir} do
    test_pid = self()

    responder = fn request ->
      send(test_pid, {:system_prompt, request.system_prompt})
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, _} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [],
               capabilities: %{native_tool_calls: false}
             )

    assert_receive {:system_prompt, sp}
    assert sp =~ "~~~tool_call"
  end

  test "without capabilities override, native Mock provider does NOT get the preamble",
       %{dir: dir} do
    test_pid = self()

    responder = fn request ->
      send(test_pid, {:system_prompt, request.system_prompt})
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, _} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: []
             )

    assert_receive {:system_prompt, sp}
    refute (sp || "") =~ "~~~tool_call"
  end

  test "capabilities override: fenced tool call in text is parsed and dispatched", %{dir: dir} do
    File.write!(Path.join(dir, "hello.txt"), "hello world")

    responses = [
      %Response{
        text: "~~~tool_call\n{\"name\": \"read\", \"arguments\": {\"path\": \"hello.txt\"}}\n~~~",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      },
      %Response{text: "file read ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    assert {:ok, result} =
             Loop.run("read hello.txt",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               capabilities: %{native_tool_calls: false}
             )

    assert result.text == "file read ok"
    assert result.iterations == 1
    assert Enum.any?(result.messages, &match?(%{role: :tool}, &1))
  end

  test "plan_mode tool changes the ctx phase mid-loop", %{dir: dir} do
    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "plan_mode", arguments: %{"action" => "exit"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "now I can write",
        tool_calls: [
          %ToolCall{id: "c2", name: "write", arguments: %{"path" => "new.txt", "content" => "hi"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    # Start in :plan phase — write is initially blocked. plan_mode exit flips to :default.
    assert {:ok, result} =
             Loop.run("begin",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               phase: :plan,
               tools: [ExAthena.Tools.PlanMode, ExAthena.Tools.Write]
             )

    assert result.text == "done"
    assert File.read!(Path.join(dir, "new.txt")) == "hi"
  end

  test "images: shorthand reaches the provider as ContentPart content", %{dir: dir} do
    alias ExAthena.Messages.ContentPart

    png = <<0::8>>

    responder = fn request ->
      user_msg = Enum.find(request.messages, &(&1.role == :user))

      assert [%ContentPart{type: :text, text: "describe"}, %ContentPart{type: :image}] =
               user_msg.content

      %Response{text: "saw image", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, result} =
             Loop.run("describe",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [],
               images: [%{data: png, media_type: "image/png"}]
             )

    assert result.text == "saw image"
  end

  test "loop dispatches capabilities/1 when provider exports it", %{dir: dir} do
    Process.put(:caps1_test_parent, self())

    assert {:ok, result} =
             Loop.run("hi",
               provider: CapabilitiesV1Provider,
               model: "test-model",
               cwd: dir,
               tools: []
             )

    assert result.text == "caps1 response"
    assert_received {:caps1_called, opts}
    assert Keyword.get(opts, :model) == "test-model"
  end

  test "loop falls back to capabilities/0 for providers without capabilities/1", %{dir: dir} do
    responses = [
      %Response{text: "fallback ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    assert {:ok, result} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: script(responses)],
               cwd: dir,
               tools: []
             )

    assert result.text == "fallback ok"
  end
end
