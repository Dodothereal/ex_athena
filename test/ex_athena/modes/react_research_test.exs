defmodule ExAthena.Modes.ReactResearch.EmptyGrep do
  @moduledoc false
  @behaviour ExAthena.Tool
  def name, do: "grep"
  def description, do: "test grep that finds nothing"

  def schema,
    do: %{type: "object", properties: %{pattern: %{type: "string"}}, required: ["pattern"]}

  def parallel_safe?, do: true
  def execute(_args, _ctx), do: {:ok, "No matches found."}
end

defmodule ExAthena.Modes.ReactResearchTest do
  use ExUnit.Case, async: true

  import Mox

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Modes.ReactResearch.EmptyGrep
  alias ExAthena.Tools.WebSearch

  @directive_marker "[runtime] Local context looks insufficient"

  setup :verify_on_exit!

  setup do
    dir = Path.join(System.tmp_dir!(), "react_res_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      case Enum.at(responses, n - 1) || List.last(responses) do
        fun when is_function(fun, 2) -> fun.(n, request)
        resp -> resp
      end
    end
  end

  defp request_text(request) do
    Enum.map_join(request.messages, "\n", fn m ->
      case m.content do
        c when is_binary(c) -> c
        _ -> ""
      end
    end)
  end

  test "injects a research directive after an empty local search", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "grep", arguments: %{"pattern" => "zzz"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      fn _n, request ->
        send(test_pid, {:request, request})

        %Response{
          text: "done\nCONCLUSION: done.",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end
    ]

    assert {:ok, %Result{}} =
             Loop.run("find the thing",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: [EmptyGrep, WebSearch],
               mode: :react
             )

    assert_receive {:request, request}
    assert request_text(request) =~ @directive_marker
  end

  test "does NOT inject the directive when web_search is not in scope", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "grep", arguments: %{"pattern" => "zzz"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      fn _n, request ->
        send(test_pid, {:request, request})

        %Response{
          text: "done\nCONCLUSION: done.",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end
    ]

    assert {:ok, %Result{}} =
             Loop.run("find the thing",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               # No WebSearch tool → no point steering toward it.
               tools: [EmptyGrep],
               mode: :react
             )

    assert_receive {:request, request}
    refute request_text(request) =~ @directive_marker
  end

  test "stops nudging after the web_search over-search cap is hit", %{dir: dir} do
    test_pid = self()
    stub(ExAthena.Search.Mock, :search, fn _q, _opts -> {:ok, []} end)

    web = fn id ->
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: id, name: "web_search", arguments: %{"query" => "q"}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end

    responses = [
      web.("w1"),
      web.("w2"),
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "g1", name: "grep", arguments: %{"pattern" => "zzz"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      fn _n, request ->
        send(test_pid, {:request, request})

        %Response{
          text: "done\nCONCLUSION: done.",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end
    ]

    assert {:ok, %Result{}} =
             Loop.run("find the thing",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: [EmptyGrep, WebSearch],
               mode: :react
             )

    assert_receive {:request, request}
    # grep just came back empty (a signal), but two web_searches already ran —
    # the cap suppresses further nudging.
    refute request_text(request) =~ @directive_marker
  end
end
