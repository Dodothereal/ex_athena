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

  test "planning turns carry DELEGATION-ONLY tools and the planning addendum", %{dir: dir} do
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
               tools: ExAthena.Tools.builtins() ++ [ExAthena.Tools.AskUser],
               mode: :orchestrate
             )

    assert_receive {:planning_request, request}
    names = schema_names(request.tools)

    # Exploration agents are MANDATORY: no direct exploration tools at all
    # (live testing: given read/glob, a small model explores directly every
    # time and never delegates). The toolset is IDENTICAL across phases —
    # tool schemas render into the prompt prefix, so a phase-varying
    # toolset breaks prefix caching on local servers.
    assert "spawn_agent" in names
    assert "ask_user" in names
    assert "todo_write" in names
    assert "finish" in names
    refute "read" in names
    refute "glob" in names
    refute "grep" in names
    refute "web_fetch" in names
    refute "bash" in names
    refute "write" in names
    refute "edit" in names

    # The union protocol (plan-first + delegation) lives in the system
    # prompt, byte-stable across phases.
    assert request.system_prompt =~ "draft plan"
    assert request.system_prompt =~ "todo_write"
    assert request.system_prompt =~ "explore"

    # Phase steering is EPHEMERAL, at the request tail (cache-safe) —
    # never persisted into the transcript.
    last = List.last(request.messages)
    assert last.role == :user
    assert last.content =~ "PLANNING"
  end

  test "the system prompt is BYTE-STABLE across planning and executing (prefix cache)", %{
    dir: dir
  } do
    test_pid = self()

    responses = [
      fn _n, request ->
        send(test_pid, {:planning_sp, request.system_prompt})
        %Response{text: "1. step A", tool_calls: [], finish_reason: :stop, provider: :mock}
      end,
      fn _n, request ->
        send(test_pid, {:exec_sp, request.system_prompt})
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("build it",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               tools: ExAthena.Tools.builtins() ++ [ExAthena.Tools.AskUser],
               mode: :orchestrate
             )

    assert_receive {:planning_sp, planning_sp}
    assert_receive {:exec_sp, exec_sp}
    assert planning_sp == exec_sp
  end

  test "planning may DELEGATE exploration across turns, then a tool-free plan transitions to executing",
       %{dir: dir} do
    test_pid = self()

    responses = [
      # Planning turn 1: delegates exploration to a worker.
      %Response{
        text: "Let me have a worker look first.",
        tool_calls: [
          %ToolCall{
            id: "p1",
            name: "spawn_agent",
            arguments: %{"prompt" => "explore the repo structure and report back"}
          }
        ],
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
               memory: false,
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate,
               assigns: %{
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [text: "repo uses NimblePublisher under web/priv"],
                   tools: [],
                   memory: false
                 ]
               }
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

  test "recording todos DURING planning ends planning (the plan is the todo list)", %{dir: dir} do
    test_pid = self()

    todos_args = %{
      "todos" => [
        %{"content" => "create the blog post", "status" => "pending"},
        %{"content" => "publish it", "status" => "pending"}
      ]
    }

    responses = [
      # Planning turn 1: the model records its plan straight into todo_write
      # (observed live — rejecting this burned the turn).
      %Response{
        text: "I have what I need. Recording my plan.",
        tool_calls: [%ToolCall{id: "t1", name: "todo_write", arguments: todos_args}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      # Next turn must be EXECUTING.
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
               memory: false,
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate
             )

    assert_receive {:exec_request, request}
    names = schema_names(request.tools)
    assert "finish" in names
    assert request.system_prompt =~ "Orchestration protocol"
    refute request.system_prompt =~ "Planning phase"
  end

  test "a worker's REQUEST timeout matches the spawn timeout, not the 60s default", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "do the step"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn request ->
      send(test_pid, {:worker_timeout, request.timeout_ms})
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

    # Observed live: the 60_000 Request default became receive_timeout and
    # killed workers whose prompts made exo prompt-process >60s. The spawn
    # wall clock (30 min) covers the full 75-iteration worker budget.
    assert_receive {:worker_timeout, 1_800_000}
  end

  test "the default worker budget covers a 30-turn task (tripled for small models)", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "long task"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    # Worker needs 31 turns: 30 DISTINCT tool calls (one per turn — the
    # local-model rhythm), then the final summary. Died at the old 25-cap.
    sub_counter = :counters.new(1, [:atomics])

    sub_responder = fn _request ->
      :counters.add(sub_counter, 1, 1)
      n = :counters.get(sub_counter, 1)

      if n <= 30 do
        %Response{
          text: "CONCLUSION: step #{n} done.",
          tool_calls: [
            %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "f.txt", "offset" => n}}
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "worker summary", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
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
    refute tr.is_error
    assert tr.content =~ "worker summary"
  end

  test "a worker given an explicit tools list ALWAYS keeps todo_write", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "spawn_agent",
            arguments: %{"prompt" => "do the step", "tools" => ["read"]}
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn request ->
      send(test_pid, {:worker_request, request})
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

    assert_receive {:worker_request, request}
    names = schema_names(request.tools)
    assert "read" in names
    # The worker contract demands todo upkeep — it can never be stripped.
    assert "todo_write" in names
  end

  test "a worker ALWAYS runs in the parent's cwd — model-supplied cwd is ignored", %{dir: dir} do
    # Marker exists ONLY in the parent's project dir.
    File.write!(Path.join(dir, "marker.txt"), "parent-data")
    elsewhere = Path.join(System.tmp_dir!(), "elsewhere_#{System.unique_integer([:positive])}")
    File.mkdir_p!(elsewhere)
    on_exit(fn -> File.rm_rf!(elsewhere) end)

    test_pid = self()

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "spawn_agent",
            # The model tries to point the worker at another directory.
            arguments: %{"prompt" => "read marker.txt", "cwd" => elsewhere}
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_counter = :counters.new(1, [:atomics])

    sub_responder = fn request ->
      :counters.add(sub_counter, 1, 1)

      case :counters.get(sub_counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "r1", name: "read", arguments: %{"path" => "marker.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          send(test_pid, {:worker_messages, request.messages})
          %Response{text: "worker done", tool_calls: [], finish_reason: :stop, provider: :mock}
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

    assert_receive {:worker_messages, messages}
    [tool_msg] = Enum.filter(messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    # Relative read resolved against the PARENT's cwd, not "elsewhere".
    assert tr.content =~ "parent-data"
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

  test "a failed worker hands back Completed/Remaining so the retry skips finished work", %{
    dir: dir
  } do
    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "explore the repo"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    worker_todos = %{
      "todos" => [
        %{"content" => "examined blog controller", "status" => "completed"},
        %{"content" => "review nimble usage", "status" => "pending"}
      ]
    }

    # Worker: records sub-todos with a STATED finding, then spins into the
    # no-progress guard (same blank looping turn repeated).
    sub_counter = :counters.new(1, [:atomics])

    sub_responder = fn _request ->
      :counters.add(sub_counter, 1, 1)

      case :counters.get(sub_counter, 1) do
        1 ->
          %Response{
            text: "CONCLUSION: blog controller uses NimblePublisher pattern.",
            tool_calls: [
              %ToolCall{id: "w1", name: "todo_write", arguments: worker_todos}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{
            text: " ",
            tool_calls: [
              %ToolCall{id: "w2", name: "read", arguments: %{"path" => "nope.txt"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }
      end
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
                   tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.Read],
                   memory: false
                 ]
               }
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    assert tr.is_error
    # Structured handoff: completed AND remaining work, plus stated findings
    # (not "ran bash" noise).
    assert tr.content =~ "Completed"
    assert tr.content =~ "examined blog controller"
    assert tr.content =~ "Remaining"
    assert tr.content =~ "review nimble usage"
    assert tr.content =~ "NimblePublisher pattern"
  end

  test "calling a phase-unavailable builtin redirects the model to delegate", %{dir: dir} do
    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      # Executing phase: the model hallucinates `read` (observed live —
      # planning allowed it, executing doesn't).
      %Response{
        text: "let me peek",
        tool_calls: [%ToolCall{id: "t1", name: "read", arguments: %{"path" => "x.ex"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "ok, delegating instead",
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
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    assert tr.is_error
    assert tr.content =~ "read"
    assert tr.content =~ "spawn_agent"
  end

  test "a worker that finishes via the finish tool contributes its deliverable", %{dir: dir} do
    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "spawn_agent",
            arguments: %{
              "prompt" => "examine the file",
              "objective" => "examine services.ex",
              "expected_output" => "the pattern summary"
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    # Worker ends by calling finish with a deliverable and NO final text.
    sub_responder = fn _request ->
      %Response{
        text: "",
        tool_calls: [
          %ToolCall{
            id: "f1",
            name: "finish",
            arguments: %{"deliverable" => "NimblePublisher pattern: priv markdown + module"}
          }
        ],
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
                   tools: [ExAthena.Tools.Finish],
                   memory: false
                 ]
               }
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    refute tr.is_error
    assert tr.content =~ "NimblePublisher pattern"
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
