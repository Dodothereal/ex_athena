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

  defp schema_names(tools) do
    Enum.map(tools || [], fn t ->
      t[:name] || t["name"] || get_in(t, [:function, :name]) || get_in(t, ["function", "name"])
    end)
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

  test "planning turns carry READ-ONLY exploration tools and the planning addendum", %{dir: dir} do
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
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate
             )

    assert_receive {:planning_request, request}
    names = schema_names(request.tools)

    # Quick exploration AND delegated exploration are allowed while planning…
    assert "read" in names
    assert "glob" in names
    assert "grep" in names
    assert "web_fetch" in names
    assert "spawn_agent" in names
    # …but nothing that mutates.
    refute "bash" in names
    refute "write" in names
    refute "edit" in names

    assert request.system_prompt =~ "numbered plan"
    # The prompt pushes exploration agents over direct reads.
    assert request.system_prompt =~ "explore"
  end

  test "planning may explore across turns, then a tool-free plan transitions to executing", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "f.txt"), "x")
    test_pid = self()

    responses = [
      # Planning turn 1: explores with a read-only tool.
      %Response{
        text: "Let me look first.",
        tool_calls: [%ToolCall{id: "p1", name: "read", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      # Planning turn 2: tool-free numbered plan → ends planning.
      %Response{text: "1. do A\n2. do B", tool_calls: [], finish_reason: :stop, provider: :mock},
      # First EXECUTING turn.
      fn _n, request ->
        send(test_pid, {:exec_request, request})
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("build it",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate
             )

    assert_receive {:exec_request, request}
    # Executing phase restored the coordination toolset + execution addendum.
    names = schema_names(request.tools)
    assert "spawn_agent" in names
    refute "read" in names
    assert request.system_prompt =~ "spawn_agent"
  end

  test "the planning turn STREAMS thinking and content deltas", %{dir: dir} do
    test_pid = self()

    events = [
      %ExAthena.Streaming.Event{type: :thinking_delta, data: "planning "},
      %ExAthena.Streaming.Event{type: :thinking_delta, data: "the steps"},
      %ExAthena.Streaming.Event{type: :text_delta, data: "1. step A"}
    ]

    responses = [
      %Response{
        text: "1. step A",
        thinking: "planning the steps",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("build it",
               provider: :mock,
               mock: [responder: scripted(responses)],
               mock_events: events,
               cwd: dir,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
               mode: :orchestrate,
               on_event: fn ev -> send(test_pid, {:event, ev}) end
             )

    # Deltas arrive as chunks (streamed), and the end-of-turn full-text
    # re-emission is suppressed — no duplicated blob.
    assert_receive {:event, {:thinking, "planning "}}
    assert_receive {:event, {:thinking, "the steps"}}
    assert_receive {:event, {:content, "1. step A"}}
    refute_received {:event, {:thinking, "planning the steps"}}
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
    tool_specs =
      ExAthena.Tools.resolve(tools: ExAthena.Tools.builtins() ++ [ExAthena.Tools.AskUser])

    {:ok, state} =
      ExAthena.Modes.Orchestrate.init(%ExAthena.Loop.State{
        max_concurrency: 4,
        tool_specs: tool_specs,
        meta: %{provider_atom: :mock},
        ctx: ExAthena.ToolContext.new(cwd: dir, assigns: %{}),
        request_template: %ExAthena.Request{messages: [], system_prompt: nil}
      })

    names = Enum.map(state.tool_specs, & &1.name)

    # Coordination tools ONLY — no specialist tools on the supervisor
    # (LangGraph rule, no exceptions): even read/glob/grep let a small model
    # burn all its iterations on self-investigation instead of delegating.
    assert Enum.sort(names) == Enum.sort(~w(todo_write spawn_agent finish ask_user))
  end

  test "auto-delegation: pending todos + 2 spawn-less turns → the runtime spawns the worker",
       %{dir: dir} do
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    todos_args = %{
      "todos" => [
        %{"content" => "write the blog post", "status" => "pending"},
        %{"content" => "publish it", "status" => "pending"}
      ]
    }

    responder = fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:main_request, n, request.messages})

      case n do
        1 ->
          %Response{text: "the plan", tool_calls: [], finish_reason: :stop, provider: :mock}

        n when n in [2, 3] ->
          # Two executing turns that write todos but never delegate.
          %Response{
            text: "Organizing todos.",
            tool_calls: [
              %ToolCall{id: "t#{n}", name: "todo_write", arguments: todos_args}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{
            text: "done\nCONCLUSION: integrated worker output.",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }
      end
    end

    sub_responder = fn _request ->
      %Response{
        text: "Worker finished the blog post.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end

    on_event = fn ev -> send(test_pid, {:event, ev}) end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
               mode: :orchestrate,
               on_event: on_event,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [responder: sub_responder],
                   tools: [],
                   memory: false
                 ]
               }
             )

    # The runtime (not the model) delegated the first pending todo.
    assert_receive {:event, {:subagent_spawn, %{prompt: prompt}}}
    assert prompt =~ "write the blog post"
    assert_receive {:event, {:subagent_result, %{text: "Worker finished the blog post."}}}

    # The worker's summary was injected back into the orchestrator's context.
    assert_receive {:main_request, 4, msgs}

    assert Enum.any?(msgs, fn
             %{role: :user, content: c} when is_binary(c) ->
               c =~ "orchestration runtime" and c =~ "Worker finished the blog post."

             _ ->
               false
           end)
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
    assert state.mode_state.phase == :planning
  end

  test "orchestrate is uncapped by default but respects an explicit max_iterations", %{dir: dir} do
    base = %ExAthena.Loop.State{
      max_iterations: 25,
      meta: %{provider_atom: :mock},
      ctx: ExAthena.ToolContext.new(cwd: dir, assigns: %{}),
      request_template: %ExAthena.Request{messages: [], system_prompt: nil}
    }

    # Default cap (caller passed nothing) → unlimited; the remaining guards
    # (no-progress, mistakes, budget, host Stop) bound the run instead.
    {:ok, state} = ExAthena.Modes.Orchestrate.init(base)
    assert state.max_iterations == :infinity

    # Caller explicitly asked for a cap → honored.
    explicit = %{
      base
      | max_iterations: 40,
        meta: Map.put(base.meta, :explicit_max_iterations?, true)
    }

    {:ok, state} = ExAthena.Modes.Orchestrate.init(explicit)
    assert state.max_iterations == 40
  end

  test "a spawn with ONLY a prompt gets a fully defaulted brief (nothing is rejected)", %{
    dir: dir
  } do
    test_pid = self()

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "just do the step"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn request ->
      send(test_pid, {:worker_prompt, List.last(request.messages).content})
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

    assert_receive {:worker_prompt, text}
    # Objective defaults from the prompt; the rest from runtime defaults.
    assert text =~ "Objective: just do the step"
    assert text =~ "self-contained summary"
    assert text =~ "only this step"
  end

  test "a brief missing only boundaries/tool_guidance is auto-filled and the spawn proceeds",
       %{dir: dir} do
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
              "prompt" => "explore the repo",
              "objective" => "map the repo structure",
              "expected_output" => "a summary of directory patterns"
              # boundaries + tool_guidance omitted — Qwen3.5-class models
              # consistently drop them; the runtime fills defaults.
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
      send(test_pid, {:worker_prompt, List.last(request.messages).content})
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

    assert_receive {:worker_prompt, text}
    assert text =~ "map the repo structure"
    # The runtime-filled default boundary made it into the worker brief.
    assert text =~ "only this step"
  end

  test "failed spawn attempts do not count as delegation for the watchdog", %{dir: dir} do
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    todos_args = %{"todos" => [%{"content" => "explore the repo", "status" => "pending"}]}

    # A spawn with no prompt at all — the one shape that still fails; the
    # model repeats it verbatim (observed live behavior).
    bad_spawn = %ToolCall{id: "bad", name: "spawn_agent", arguments: %{}}

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock}

        2 ->
          %Response{
            text: "Trying to delegate. Attempt one.",
            tool_calls: [
              %ToolCall{id: "t2", name: "todo_write", arguments: todos_args},
              bad_spawn
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        3 ->
          %Response{
            text: "Trying to delegate. Attempt two.",
            tool_calls: [%{bad_spawn | id: "bad2"}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    sub_responder = fn _request ->
      %Response{
        text: "Worker explored the repo.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end

    on_event = fn ev -> send(test_pid, {:event, ev}) end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               memory: false,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
               mode: :orchestrate,
               on_event: on_event,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [responder: sub_responder],
                   tools: [],
                   memory: false
                 ]
               }
             )

    # Despite two (failed) spawn attempts, the watchdog still rescued the
    # pending todo with a real worker.
    assert_receive {:event, {:subagent_result, %{text: "Worker explored the repo."}}}
  end

  test "unknown tool names in spawn args are dropped instead of crashing the worker", %{dir: dir} do
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
              "prompt" => "explore",
              "objective" => "explore the repo",
              "expected_output" => "a summary",
              # Shell commands, not ex_athena tools — observed live; the
              # sub-loop used to raise ArgumentError and crash the worker.
              "tools" => ["ls", "tree", "read"]
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn request ->
      send(test_pid, {:sub_tools, request.tools})
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
                   memory: false
                 ]
               }
             )

    assert_receive {:sub_tools, tools}
    names = Enum.map(tools, fn t -> t[:name] || t["name"] || get_in(t, [:function, :name]) end)
    assert "read" in names
    refute "ls" in names
  end

  test "a model-passed worker iteration cap is floored at the default", %{dir: dir} do
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
              "prompt" => "explore",
              "objective" => "explore the repo",
              "expected_output" => "a summary",
              # Live behavior: the orchestrator starved its worker with a
              # tiny cap (5) and the worker died at error_max_turns.
              "max_iterations" => 1
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    File.write!(Path.join(dir, "a.txt"), "x")
    sub_counter = :counters.new(1, [:atomics])

    # The worker needs 3 iterations — under the raw cap of 1 it would die.
    sub_responder = fn _request ->
      :counters.add(sub_counter, 1, 1)
      n = :counters.get(sub_counter, 1)

      if n <= 3 do
        %Response{
          text: "step #{n}",
          tool_calls: [%ToolCall{id: "s#{n}", name: "read", arguments: %{"path" => "a#{n}.txt"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        send(test_pid, :worker_finished)
        %Response{text: "worker summary", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
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
                   tools: [ExAthena.Tools.Read],
                   memory: false
                 ]
               }
             )

    assert_receive :worker_finished
  end

  test "a worker that ends without finishing surfaces an error to the orchestrator", %{dir: dir} do
    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "spawn_agent",
            arguments: %{
              "prompt" => "explore",
              "objective" => "explore the repo",
              "expected_output" => "a summary"
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "understood, re-delegating later",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    ]

    File.write!(Path.join(dir, "same.txt"), "x")

    # Worker loops identically → trips its no-progress guard → error Result.
    sub_responder = fn _request ->
      %Response{
        text: " ",
        tool_calls: [%ToolCall{id: "s", name: "read", arguments: %{"path" => "same.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end

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
                   mock: [responder: sub_responder],
                   tools: [ExAthena.Tools.Read],
                   memory: false
                 ]
               }
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    assert tr.is_error
    assert tr.content =~ "did not finish"
    assert tr.content =~ "error_no_progress"
    # The worker's learnings survive the failure: its conclusions ledger is
    # digested into the error so the orchestrator keeps the knowledge.
    assert tr.content =~ "ran read"
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
