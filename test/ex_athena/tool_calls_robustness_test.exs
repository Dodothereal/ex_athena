defmodule ExAthena.ToolCallsRobustnessTest do
  @moduledoc """
  Small-model tool-call robustness (June-2026 audit): malformed JSON args,
  duplicate ids, leaked XML tool calls, and prose-quoted JSON must never
  kill a run — every failure becomes a per-call error the model can repair.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, ToolCalls}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolCalls.Native

  describe "Native.parse/1 resilience" do
    test "malformed JSON args become a repairable sentinel call, not a batch failure" do
      calls = [
        %{
          "type" => "function",
          "id" => "ok1",
          "function" => %{"name" => "read", "arguments" => ~s({"path":"a.txt"})}
        },
        %{
          "type" => "function",
          "id" => "bad",
          "function" => %{"name" => "read", "arguments" => ~s({"path": "b.txt",})}
        }
      ]

      assert {:ok, [good, repaired_or_sentinel]} = Native.parse(calls)
      assert good.arguments == %{"path" => "a.txt"}
      # Trailing comma is repaired (common 9B breakage)…
      assert repaired_or_sentinel.arguments == %{"path" => "b.txt"}
    end

    test "unrepairable JSON args yield a sentinel the loop can error per-call" do
      calls = [
        %{
          "type" => "function",
          "id" => "bad",
          "function" => %{"name" => "read", "arguments" => "{totally broken"}
        }
      ]

      assert {:ok, [sentinel]} = Native.parse(calls)
      assert sentinel.name == "read"
      assert is_binary(sentinel.arguments["__invalid_json__"])
    end

    test "exact duplicate calls are deduped; id collisions are re-id'd" do
      dup = %{
        "type" => "function",
        "id" => "x",
        "function" => %{"name" => "read", "arguments" => ~s({"path":"a"})}
      }

      collide = %{
        "type" => "function",
        "id" => "x",
        "function" => %{"name" => "read", "arguments" => ~s({"path":"b"})}
      }

      assert {:ok, calls} = Native.parse([dup, dup, collide])
      assert length(calls) == 2
      [a, b] = calls
      assert a.id != b.id
      assert a.arguments == %{"path" => "a"}
      assert b.arguments == %{"path" => "b"}
    end
  end

  describe "ToolCalls.extract/2 fallback tiers" do
    test "leaked <tool_call> XML in content is extracted (exo/Qwen leak)" do
      response = %{
        text:
          ~s(Let me check.\n<tool_call>\n{"name": "read", "arguments": {"path": "f.txt"}}\n</tool_call>),
        tool_calls: []
      }

      assert {:ok, [call]} = ToolCalls.extract(response, %{native_tool_calls: true})
      assert call.name == "read"
      assert call.arguments == %{"path" => "f.txt"}
    end

    test "JSON quoted mid-prose is NOT executed (terminal answers stay terminal)" do
      response = %{
        text: """
        I finished the task. For reference, the call I used was
        {"name": "read", "arguments": {"path": "f.txt"}} and it worked.
        """,
        tool_calls: []
      }

      assert {:ok, []} = ToolCalls.extract(response, %{native_tool_calls: true})
    end

    test "a message that IS bare JSON still parses (non-native models)" do
      response = %{text: ~s({"name": "read", "arguments": {"path": "f.txt"}}), tool_calls: []}
      assert {:ok, [call]} = ToolCalls.extract(response, %{native_tool_calls: true})
      assert call.name == "read"
    end
  end

  describe "loop survival" do
    setup do
      dir = Path.join(System.tmp_dir!(), "robust_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "a turn with THREE bad calls bumps mistakes ONCE — the run survives to retry", %{
      dir: dir
    } do
      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %Response{
              text: "",
              tool_calls: [
                %ToolCall{id: "a", name: "nope1", arguments: %{}},
                %ToolCall{id: "b", name: "nope2", arguments: %{}},
                %ToolCall{id: "c", name: "nope3", arguments: %{}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "recovered", tool_calls: [], finish_reason: :stop, provider: :mock}
        end
      end

      assert {:ok, result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read]
               )

      # Pre-fix this died :error_consecutive_mistakes before the model ever
      # saw the redirect errors.
      assert result.finish_reason == :stop
      assert result.text == "recovered"
    end

    test "a tool raising in the SERIAL path becomes an error result, not a crash", %{dir: dir} do
      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %Response{
              text: "",
              tool_calls: [
                # edit is serial (parallel_safe? false); replace_all as a
                # STRING raises FunctionClauseError pre-fix.
                %ToolCall{
                  id: "e1",
                  name: "edit",
                  arguments: %{
                    "path" => "f.txt",
                    "old_string" => "a",
                    "new_string" => "b",
                    "replace_all" => "true"
                  }
                }
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "recovered", tool_calls: [], finish_reason: :stop, provider: :mock}
        end
      end

      File.write!(Path.join(dir, "f.txt"), "aaa")

      assert {:ok, result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [ExAthena.Tools.Edit]
               )

      assert result.finish_reason == :stop
    end

    test "invalid-JSON sentinel produces a per-call repair error for the model", %{dir: dir} do
      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %Response{
              text: "",
              tool_calls: [
                %ToolCall{id: "s1", name: "read", arguments: %{"__invalid_json__" => "{broken"}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "fixed", tool_calls: [], finish_reason: :stop, provider: :mock}
        end
      end

      assert {:ok, result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read]
               )

      [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
      [tr] = tool_msg.tool_results
      assert tr.is_error
      assert tr.content =~ "not valid JSON"
      assert result.finish_reason == :stop
    end
  end
end
