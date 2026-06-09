defmodule ExAthena.Modes.OrchestrateResearchTest do
  @moduledoc """
  The deterministic research rail in orchestrate-mode planning: a context-starved
  planning phase (no plan recorded after the threshold turns) gets steered, once,
  to delegate online research.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  @marker "PLANNING is stalling"

  setup do
    dir = Path.join(System.tmp_dir!(), "orch_res_#{System.unique_integer([:positive])}")
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

  test "stalling planning (no plan after the threshold) injects a research directive", %{dir: dir} do
    test_pid = self()

    # Each planning turn spawns a throwaway worker WITHOUT recording todos, so
    # planning never transitions — letting planning_turns climb to the threshold.
    orch = fn n, request ->
      send(test_pid, {:orch_request, n, request})

      if n <= 5 do
        %Response{
          text: "",
          tool_calls: [
            %ToolCall{
              id: "s#{n}",
              name: "spawn_agent",
              arguments: %{"prompt" => "look around area #{n}"}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{
          text: "1. do it\nCONCLUSION: done.",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end
    end

    sub_responder = fn _request ->
      %Response{
        text: "nothing useful found",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end

    assert {:ok, %Result{}} =
             Loop.run("build a thing needing external facts",
               provider: :mock,
               mock: [responder: scripted([orch])],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.SpawnAgent],
               mode: :orchestrate,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [responder: sub_responder],
                   tools: [],
                   memory: false
                 ]
               }
             )

    # Threshold is 4 → the nudge is set after turn 4, so it rides on request 5.
    assert_receive {:orch_request, 5, req5}
    assert request_text(req5) =~ @marker

    # Early planning turns carry the normal planning note, not the research nudge.
    assert_receive {:orch_request, 1, req1}
    refute request_text(req1) =~ @marker
  end

  test "a healthy plan recorded early never triggers the research nudge", %{dir: dir} do
    test_pid = self()

    orch = fn n, request ->
      send(test_pid, {:orch_request, n, request})

      case n do
        1 ->
          %Response{
            text: "",
            tool_calls: [
              %ToolCall{
                id: "p1",
                name: "todo_write",
                arguments: %{"todos" => [%{"content" => "do it", "status" => "completed"}]}
              }
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "all done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{}} =
             Loop.run("simple task",
               provider: :mock,
               mock: [responder: scripted([orch])],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.SpawnAgent],
               mode: :orchestrate
             )

    # Collect every captured request; none should carry the research nudge.
    texts = drain_requests()
    refute Enum.any?(texts, &(&1 =~ @marker))
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:orch_request, _n, req} -> drain_requests([request_text(req) | acc])
    after
      0 -> acc
    end
  end
end
