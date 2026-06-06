defmodule ExAthena.Modes.OrchestrateTest do
  @moduledoc """
  The :orchestrate mode — prompt-driven delegation inside deterministic
  runtime rails (depth-1, fan-out = provider slots, strict spawn briefs,
  todo-driven execution).
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Loop.Mode
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "orch_#{System.unique_integer([:positive])}")
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

  test "Mode.resolve(:orchestrate) returns the module" do
    assert Mode.resolve(:orchestrate) == ExAthena.Modes.Orchestrate
  end

  test "the planning turn is tool-free with the orchestration planning addendum", %{dir: dir} do
    test_pid = self()

    responses = [
      fn _n, request ->
        send(test_pid, {:planning_request, request})

        %Response{
          text: "1. step A\n2. step B",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end,
      %Response{
        text: "done\nCONCLUSION: finished.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("build the feature",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
               mode: :orchestrate
             )

    assert_receive {:planning_request, request}
    assert request.tools == nil
    assert request.system_prompt =~ "todo"
  end

  test "the execution addendum mandates delegation and todo upkeep", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{text: "plan made", tool_calls: [], finish_reason: :stop, provider: :mock},
      fn _n, request ->
        send(test_pid, {:exec_request, request})

        %Response{
          text: "ok\nCONCLUSION: done.",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end
    ]

    Loop.run("go",
      provider: :mock,
      mock: [responder: scripted(responses)],
      cwd: dir,
      tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
      mode: :orchestrate
    )

    assert_receive {:exec_request, request}
    assert request.system_prompt =~ "spawn_agent"
    assert request.system_prompt =~ "todo_write"
  end

  test "the orchestrator keeps only coordination + read-only tools (no bash/write/edit)", %{
    dir: dir
  } do
    tool_specs = ExAthena.Tools.resolve(tools: ExAthena.Tools.builtins())

    {:ok, state} =
      ExAthena.Modes.Orchestrate.init(%ExAthena.Loop.State{
        max_concurrency: 4,
        tool_specs: tool_specs,
        meta: %{provider_atom: :mock},
        ctx: ExAthena.ToolContext.new(cwd: dir, assigns: %{}),
        request_template: %ExAthena.Request{messages: [], system_prompt: nil}
      })

    names = Enum.map(state.tool_specs, & &1.name)

    # Coordination + read-only investigation stays…
    assert "todo_write" in names
    assert "spawn_agent" in names
    assert "finish" in names
    assert "read" in names

    # …but the supervisor gets NO specialist/mutating tools (LangGraph
    # supervisor rule) — that's what workers are for.
    refute "bash" in names
    refute "write" in names
    refute "edit" in names
    refute "apply_patch" in names
  end

  test "fan-out is capped at the provider's queue slots", %{dir: dir} do
    # :mock has no override here → cloud default 10, but orchestrate caps
    # at min(slots, configured max_concurrency).
    Application.put_env(:ex_athena, :mock, request_queue: [max_depth: 1])
    on_exit(fn -> Application.delete_env(:ex_athena, :mock) end)

    {:ok, state} =
      ExAthena.Modes.Orchestrate.init(%ExAthena.Loop.State{
        max_concurrency: 4,
        meta: %{provider_atom: :mock},
        ctx: ExAthena.ToolContext.new(cwd: dir, assigns: %{}),
        request_template: %ExAthena.Request{messages: [], system_prompt: nil}
      })

    assert state.max_concurrency == 1
    assert state.ctx.assigns[:strict_spawn] == true
    assert state.ctx.assigns[:subagent_prompt_suffix] =~ "CONCLUSION"
    assert state.mode_state == %{phase: :planning}
  end

  test "strict spawn briefs: missing fields are rejected with a model-visible error", %{dir: dir} do
    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "just do it"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "ok I'll fix the brief",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    assert {:ok, %Result{} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.SpawnAgent],
               mode: :orchestrate,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [text: "never runs"],
                   tools: [],
                   memory: false
                 ]
               }
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    assert tr.is_error
    assert tr.content =~ "objective"
    assert tr.content =~ "expected_output"
  end

  test "depth-1: a subagent cannot spawn further subagents", %{dir: dir} do
    ctx =
      ExAthena.ToolContext.new(
        cwd: dir,
        session_id: "s",
        assigns: %{subagent?: true, spawn_agent_opts: [provider: :mock, mock: [text: "x"]]}
      )

    assert {:error, reason} =
             ExAthena.Tools.SpawnAgent.execute(%{"prompt" => "nested"}, ctx)

    assert reason =~ "nested"
  end

  test "a complete brief passes strict validation and reaches the worker", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "spawn_agent",
            arguments: %{
              "prompt" => "do step A",
              "objective" => "implement step A",
              "expected_output" => "a summary of changes",
              "tool_guidance" => "use read and edit",
              "boundaries" => "only touch lib/a.ex"
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "done\nCONCLUSION: integrated.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    sub_responder = fn request ->
      send(test_pid, {:worker_prompt, List.last(request.messages)})
      %Response{text: "worker done", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
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

    assert_receive {:worker_prompt, msg}
    text = msg.content
    assert text =~ "do step A"
    assert text =~ "implement step A"
    assert text =~ "only touch lib/a.ex"
  end
end
