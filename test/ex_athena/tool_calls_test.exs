defmodule ExAthena.ToolCallsTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolCalls
  alias ExAthena.ToolCalls.{Native, TextTagged}
  alias ExAthena.Messages.ToolCall

  describe "Native.parse/1" do
    test "parses OpenAI-style tool_calls with JSON-string arguments" do
      assert {:ok, [call]} =
               Native.parse([
                 %{
                   "type" => "function",
                   "id" => "call_123",
                   "function" => %{
                     "name" => "read_file",
                     "arguments" => ~s({"path": "/tmp/foo"})
                   }
                 }
               ])

      assert %ToolCall{id: "call_123", name: "read_file", arguments: %{"path" => "/tmp/foo"}} =
               call
    end

    test "parses Claude-style tool_use blocks" do
      assert {:ok, [call]} =
               Native.parse([
                 %{
                   "type" => "tool_use",
                   "id" => "toolu_abc",
                   "name" => "read_file",
                   "input" => %{"path" => "/tmp/bar"}
                 }
               ])

      assert %ToolCall{id: "toolu_abc", name: "read_file", arguments: %{"path" => "/tmp/bar"}} =
               call
    end

    test "handles empty/missing arguments" do
      assert {:ok, [%ToolCall{arguments: %{}}]} =
               Native.parse([
                 %{
                   "type" => "function",
                   "id" => "call_1",
                   "function" => %{"name" => "ping", "arguments" => ""}
                 }
               ])
    end

    test "generates an id when missing" do
      assert {:ok, [%ToolCall{id: id}]} =
               Native.parse([%{"name" => "tool", "arguments" => %{}, "id" => nil}])

      refute is_nil(id)
    end

    test "rejects malformed JSON arguments" do
      assert {:error, _} =
               Native.parse([
                 %{
                   "type" => "function",
                   "id" => "x",
                   "function" => %{"name" => "t", "arguments" => "{not json"}
                 }
               ])
    end

    test "parses an empty list into an empty list" do
      assert {:ok, []} = Native.parse([])
    end
  end

  describe "TextTagged.parse/1" do
    test "extracts a single tool_call block" do
      text = """
      Sure, I'll read the file.

      ~~~tool_call
      {"name": "read_file", "arguments": {"path": "/tmp/foo"}}
      ~~~
      """

      assert {:ok, [%ToolCall{name: "read_file", arguments: %{"path" => "/tmp/foo"}}]} =
               TextTagged.parse(text)
    end

    test "extracts multiple tool_call blocks" do
      text = """
      ~~~tool_call
      {"name": "a", "arguments": {}}
      ~~~

      ~~~tool_call
      {"name": "b", "arguments": {"x": 1}}
      ~~~
      """

      assert {:ok, [%{name: "a"}, %{name: "b", arguments: %{"x" => 1}}]} =
               TextTagged.parse(text)
    end

    test "returns empty list when no blocks present" do
      assert {:ok, []} = TextTagged.parse("Just prose, no tools.")
    end

    test "rejects missing tool name" do
      text = "~~~tool_call\n{\"arguments\": {}}\n~~~"
      assert {:error, :missing_tool_name} = TextTagged.parse(text)
    end

    test "handles string-encoded arguments gracefully" do
      text = ~s(~~~tool_call\n{"name": "t", "arguments": "{\\"x\\": 1}"}\n~~~)

      assert {:ok, [%ToolCall{arguments: %{"x" => 1}}]} = TextTagged.parse(text)
    end
  end

  describe "extract/2 dispatch + auto-fallback" do
    test "picks Native when tool_calls are present" do
      response = %{
        tool_calls: [
          %{
            "type" => "function",
            "id" => "1",
            "function" => %{"name" => "t", "arguments" => "{}"}
          }
        ],
        text: ""
      }

      assert {:ok, [%ToolCall{name: "t"}]} = ToolCalls.extract(response)
    end

    test "falls back to TextTagged when native was claimed but returned empty" do
      response = %{
        tool_calls: nil,
        text: "~~~tool_call\n{\"name\": \"t\", \"arguments\": {}}\n~~~"
      }

      assert {:ok, [%ToolCall{name: "t"}]} =
               ToolCalls.extract(response, %{native_tool_calls: true})
    end

    test "uses TextTagged when provider declares no native tool calls" do
      response = %{
        tool_calls: nil,
        text: "~~~tool_call\n{\"name\": \"t\", \"arguments\": {}}\n~~~"
      }

      assert {:ok, [%ToolCall{name: "t"}]} =
               ToolCalls.extract(response, %{native_tool_calls: false})
    end

    test "returns empty list when no tool calls anywhere" do
      assert {:ok, []} = ToolCalls.extract(%{tool_calls: nil, text: "just text"})
    end

    test "self_contained_tools short-circuits even with a tool_call fence in text" do
      response = %{
        tool_calls: nil,
        text: "~~~tool_call\n{\"name\": \"t\", \"arguments\": {}}\n~~~"
      }

      assert {:ok, []} = ToolCalls.extract(response, %{self_contained_tools: true})
    end

    test "self_contained_tools short-circuits even with structured tool_calls present" do
      response = %{
        tool_calls: [
          %{
            "type" => "function",
            "id" => "1",
            "function" => %{"name" => "t", "arguments" => "{}"}
          }
        ],
        text: ""
      }

      assert {:ok, []} =
               ToolCalls.extract(response, %{
                 native_tool_calls: false,
                 self_contained_tools: true
               })
    end

    test "falls back to RawJson when native was claimed and text has bare JSON" do
      response = %{
        tool_calls: nil,
        text: ~s({"name":"t","arguments":{"x":1}})
      }

      assert {:ok, [%ToolCall{name: "t", arguments: %{"x" => 1}}]} =
               ToolCalls.extract(response, %{native_tool_calls: true})
    end

    test "TextTagged tier still wins over RawJson when fence is present" do
      response = %{
        tool_calls: nil,
        text: "~~~tool_call\n{\"name\": \"t\", \"arguments\": {}}\n~~~"
      }

      assert {:ok, [%ToolCall{name: "t"}]} =
               ToolCalls.extract(response, %{native_tool_calls: true})
    end

    test "RawJson fallback also active when native_tool_calls is false" do
      response = %{
        tool_calls: nil,
        text: ~s({"name":"t","arguments":{}})
      }

      assert {:ok, [%ToolCall{name: "t"}]} =
               ToolCalls.extract(response, %{native_tool_calls: false})
    end

    test "empty text and empty tool_calls returns empty list" do
      assert {:ok, []} = ToolCalls.extract(%{tool_calls: nil, text: ""})
    end
  end

  describe "augment_system_prompt/2" do
    test "adds tool-call instructions plus tool schemas" do
      prompt =
        ToolCalls.augment_system_prompt("Be helpful.", [
          %{name: "read", description: "read a file", schema: %{type: "object"}}
        ])

      assert prompt =~ "Be helpful."
      assert prompt =~ "~~~tool_call"
      assert prompt =~ "`read`"
      assert prompt =~ "read a file"
    end

    test "works with a nil base prompt" do
      assert ToolCalls.augment_system_prompt(nil, []) =~ "~~~tool_call"
    end
  end

  describe "augment_system_prompt/3 compact: true" do
    @tool_with_params %{
      name: "read_file",
      description: "Read a file from the filesystem. Returns its content.",
      schema: %{
        type: "object",
        properties: %{
          path: %{type: "string"},
          content: %{type: "string"}
        },
        required: ["path"]
      }
    }

    @tool_no_params %{
      name: "ping",
      description: "Check if the service is alive.",
      schema: %{}
    }

    @tool_array_params %{
      name: "list_files",
      description: "List files in directories.",
      schema: %{
        type: "object",
        properties: %{
          paths: %{type: "array", items: %{type: "string"}}
        },
        required: ["paths"]
      }
    }

    test "renders one-line-per-tool signature" do
      result = ToolCalls.augment_system_prompt(nil, [@tool_with_params], compact: true)
      assert result =~ "read_file("
      assert result =~ "path: string"
      assert result =~ "content?: string"
    end

    test "marks non-required params with ?" do
      result = ToolCalls.augment_system_prompt(nil, [@tool_with_params], compact: true)
      assert result =~ "content?: string"
      refute result =~ "path?:"
    end

    test "handles tools with no params" do
      result = ToolCalls.augment_system_prompt(nil, [@tool_no_params], compact: true)
      assert result =~ "ping()"
    end

    test "handles array params with scalar items" do
      result = ToolCalls.augment_system_prompt(nil, [@tool_array_params], compact: true)
      assert result =~ "paths: string[]"
    end

    test "truncates multi-sentence descriptions to first sentence" do
      result = ToolCalls.augment_system_prompt(nil, [@tool_with_params], compact: true)
      refute result =~ "Returns its content."
      assert result =~ "Read a file from the filesystem."
    end

    test "compact output is <= 80% bytes of non-compact for a 10-tool fixture" do
      tools = build_10_tool_fixture()
      compact = ToolCalls.augment_system_prompt(nil, tools, compact: true)
      full = ToolCalls.augment_system_prompt(nil, tools)
      assert byte_size(compact) <= byte_size(full) * 0.80
    end

    test "default (compact omitted) is byte-identical to pre-change behavior" do
      tools = [@tool_with_params]

      assert ToolCalls.augment_system_prompt(nil, tools) ==
               ToolCalls.augment_system_prompt(nil, tools, [])

      assert ToolCalls.augment_system_prompt(nil, tools) ==
               ToolCalls.augment_system_prompt(nil, tools, compact: false)
    end

    test "output contains ~~~tool_call fence instructions" do
      result = ToolCalls.augment_system_prompt(nil, [@tool_with_params], compact: true)
      assert result =~ "~~~tool_call"
    end

    defp build_10_tool_fixture do
      Enum.map(1..10, fn i ->
        %{
          name: "tool_#{i}",
          description:
            "Does thing number #{i} in the system. Extra details about tool #{i} that are not needed.",
          schema: %{
            type: "object",
            properties: %{
              param_a: %{type: "string"},
              param_b: %{type: "integer"},
              param_c: %{type: "boolean"},
              param_d: %{type: "object", properties: %{nested: %{type: "string"}}},
              param_e: %{type: "array", items: %{type: "string"}}
            },
            required: ["param_a", "param_b"]
          }
        }
      end)
    end
  end
end
