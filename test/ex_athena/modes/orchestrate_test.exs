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
          # The model tries to set a self-sabotaging 30s budget — a 9B
          # worker on exo runs 30-90s PER TURN, so this would kill it after
          # one turn. The runtime must ignore the model-supplied timeout.
          %ToolCall{
            id: "t1",
            name: "spawn_agent",
            arguments: %{"prompt" => "do the step", "timeout_ms" => 30_000}
          }
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

  test "the default worker budget covers a 20-turn task", %{dir: dir} do
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

    # Worker needs 21 turns: 20 DISTINCT tool calls (one per turn — the
    # local-model rhythm), then the final summary.
    sub_counter = :counters.new(1, [:atomics])

    sub_responder = fn _request ->
      :counters.add(sub_counter, 1, 1)
      n = :counters.get(sub_counter, 1)

      if n <= 20 do
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
    # The worker contract demands a complete final report (the CONCLUSION
    # line comes from the kernel's own contract, not this suffix).
    assert state.ctx.assigns[:subagent_prompt_suffix] =~ "Worker contract"
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

  test "a FAILED todo_write does NOT end planning (audit P0)", %{dir: dir} do
    test_pid = self()

    responses = [
      # Planning turn 1: todo_write with INVALID args → tool error.
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "t1", name: "todo_write", arguments: %{"wrong" => true}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      # Still planning? The request tail tells us.
      fn _n, request ->
        send(test_pid, {:request2, request})
        %Response{text: "1. do A", tool_calls: [], finish_reason: :stop, provider: :mock}
      end,
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               memory: false,
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate
             )

    assert_receive {:request2, request}
    # The rejected todo_write must not have transitioned the phase.
    assert List.last(request.messages).content =~ "PLANNING"
  end

  test "finish DURING planning is redirected, not honored as success", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{
        text: "",
        tool_calls: [
          %ToolCall{id: "f1", name: "finish", arguments: %{"deliverable" => "did nothing"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      fn _n, request ->
        send(test_pid, {:request2, request})

        %Response{
          text: "ok, planning properly now",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end,
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
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

    refute result.finish_reason == :submitted
    assert_receive {:request2, request}

    # The redirect is delivered as a TOOL RESULT for the orphaned finish
    # call (keeps the transcript valid for strict servers).
    assert Enum.any?(request.messages, fn m ->
             m.role == :tool and is_list(m.tool_results) and
               Enum.any?(m.tool_results, &(&1.content =~ "before recording any plan"))
           end)
  end

  test "finish with PENDING todos gets one nudge; the second finish is honored", %{dir: dir} do
    todos_args = %{
      "todos" => [%{"content" => "write the post", "status" => "pending"}]
    }

    finish_call = %ToolCall{id: "f", name: "finish", arguments: %{"deliverable" => "done-ish"}}

    responses = [
      # Planning: record the plan (transitions to executing).
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "t1", name: "todo_write", arguments: todos_args}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      # Executing: premature finish with the todo still pending → nudged.
      %Response{text: "", tool_calls: [finish_call], finish_reason: :tool_calls, provider: :mock},
      # Insists → honored.
      %Response{
        text: "",
        tool_calls: [%{finish_call | id: "f2"}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    ]

    assert {:ok, %Result{finish_reason: :submitted}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               memory: false,
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate
             )
  end

  test "auto-delegation never respawns the SAME todo (repeat guard)", %{dir: dir} do
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    todos_args = %{
      "todos" => [
        %{"content" => "write the blog post", "status" => "pending"},
        %{"content" => "publish it", "status" => "pending"}
      ]
    }

    # The model records todos once, then NEVER spawns and never rewrites
    # todos — the runtime must delegate todo 1, then todo 2, then STOP
    # auto-delegating (not loop on todo 1 forever).
    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "todo_write", arguments: todos_args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        n when n <= 7 ->
          # Spawn-less busywork: rewrites the SAME todos every turn.
          %Response{
            text: "organizing ##{n}",
            tool_calls: [%ToolCall{id: "t#{n}", name: "todo_write", arguments: todos_args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    sub_responder = fn request ->
      send(test_pid, {:worker_prompt, List.first(request.messages).content})
      %Response{text: "worker done", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, %Result{}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               memory: false,
               max_iterations: 12,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
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

    assert_receive {:worker_prompt, p1}
    assert p1 =~ "write the blog post"
    assert_receive {:worker_prompt, p2}
    assert p2 =~ "publish it"
    # No third auto-delegation — both todos already attempted.
    refute_receive {:worker_prompt, _}, 200
  end

  test "a bare-text stop with NO plan recorded is nudged, not silent success", %{dir: dir} do
    # Planning: a tool-free "plan" transitions to executing with NO todos.
    # The first executing turn is also bare text → must be nudged to record
    # a plan, NOT honored as success having delegated nothing.
    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        n when n <= 2 ->
          %Response{
            text: "I'll figure it out as I go.",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }

        # After the nudge, record a plan and finish properly.
        3 ->
          %Response{
            text: "",
            tool_calls: [
              %ToolCall{
                id: "t1",
                name: "todo_write",
                arguments: %{"todos" => [%{"content" => "do it", "status" => "completed"}]}
              }
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{
            text: "",
            tool_calls: [
              %ToolCall{id: "f", name: "finish", arguments: %{"deliverable" => "done"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }
      end
    end

    test_pid = self()
    on_event = fn ev -> send(test_pid, {:event, ev}) end

    assert {:ok, %Result{finish_reason: :submitted}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               memory: false,
               max_iterations: 10,
               tools: ExAthena.Tools.builtins(),
               mode: :orchestrate,
               on_event: on_event
             )

    # It did not silently succeed on the second bare-text stop.
    assert :counters.get(counter, 1) >= 4
  end

  test "a finish redirect leaves NO orphaned tool_call (strict-server safe)", %{dir: dir} do
    # finish during planning → redirected. The continued transcript must
    # not contain an assistant finish tool_call without a paired result.
    test_pid = self()
    counter = :counters.new(1, [:atomics])

    responder = fn request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [
              %ToolCall{id: "f1", name: "finish", arguments: %{"deliverable" => "nothing"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        2 ->
          send(test_pid, {:request2, request})

          %Response{
            text: "ok planning now",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }

        _ ->
          %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    Loop.run("go",
      provider: :mock,
      mock: [responder: responder],
      cwd: dir,
      memory: false,
      tools: ExAthena.Tools.builtins(),
      mode: :orchestrate
    )

    assert_receive {:request2, request}

    # Every assistant finish tool_call must have a matching tool result.
    call_ids =
      for m <- request.messages,
          m.role == :assistant,
          is_list(m.tool_calls),
          c <- m.tool_calls,
          into: MapSet.new(),
          do: c.id

    result_ids =
      for m <- request.messages,
          m.role == :tool,
          is_list(m.tool_results),
          r <- m.tool_results,
          into: MapSet.new(),
          do: r.tool_call_id

    orphans = MapSet.difference(call_ids, result_ids)
    assert MapSet.size(orphans) == 0
  end

  test "a worker that finishes with BLANK text salvages its summary from conclusions", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "f.txt"), "x")

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "explore"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    # Thinking-model worker: every turn's text channel is blank, all the
    # findings live in <think>. Its final :stop turn is blank text too →
    # extract_final_text returns "" → the orchestrator would see nothing.
    sub_counter = :counters.new(1, [:atomics])

    sub_responder = fn _request ->
      :counters.add(sub_counter, 1, 1)

      case :counters.get(sub_counter, 1) do
        1 ->
          %Response{
            text: "",
            thinking: "Looking around the project for the content layout.",
            tool_calls: [%ToolCall{id: "r1", name: "read", arguments: %{"path" => "f.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{
            text: "",
            thinking:
              "Services live in web/priv/services as markdown with YAML frontmatter; " <>
                "there is no blog directory yet.",
            tool_calls: [],
            finish_reason: :stop,
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
                   tools: [ExAthena.Tools.Read],
                   memory: false
                 ]
               }
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    refute tr.is_error
    # The orchestrator receives the worker's findings, not an empty string.
    assert tr.content =~ "no blog directory"
  end

  test "a spawn for an already-COMPLETED todo is short-circuited (no worker runs)", %{dir: dir} do
    test_pid = self()

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      # Record a plan with ALL todos completed (so nothing legitimately
      # pending triggers an auto-delegation — isolates the redundant spawn).
      %Response{
        text: "",
        tool_calls: [
          %ToolCall{
            id: "t1",
            name: "todo_write",
            arguments: %{
              "todos" => [%{"content" => "explore structure", "status" => "completed"}]
            }
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      # Model wrongly re-delegates the COMPLETED todo.
      %Response{
        text: "",
        tool_calls: [
          %ToolCall{
            id: "t2",
            name: "spawn_agent",
            arguments: %{"prompt" => "explore again", "todo" => "explore structure"}
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    sub_responder = fn _request ->
      send(test_pid, :worker_ran)
      %Response{text: "should not run", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    assert {:ok, %Result{} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: scripted(responses)],
               cwd: dir,
               memory: false,
               max_iterations: 8,
               tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
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

    # The redundant worker never ran — the spawn was short-circuited.
    refute_received :worker_ran

    # The model got an "already complete" error result for the re-delegation.
    tool_msgs = Enum.filter(result.messages, &(&1.role == :tool))

    assert Enum.any?(tool_msgs, fn m ->
             Enum.any?(m.tool_results || [], fn r ->
               r.is_error == true and r.content =~ "already complete"
             end)
           end)
  end

  test "executing turns carry a plan-status tail with findings + next pending", %{dir: dir} do
    test_pid = self()

    todos = %{
      "todos" => [
        %{"content" => "explore structure", "status" => "completed"},
        %{"content" => "write the post", "status" => "pending"}
      ]
    }

    responses = [
      %Response{text: "plan", tool_calls: [], finish_reason: :stop, provider: :mock},
      # Record the plan AND report the explore finding via a worker.
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "t1", name: "todo_write", arguments: todos}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{
        text: "",
        tool_calls: [
          %ToolCall{
            id: "t2",
            name: "spawn_agent",
            arguments: %{"prompt" => "explore", "todo" => "explore structure"}
          }
        ],
        finish_reason: :tool_calls,
        provider: :mock
      },
      # Capture the NEXT request's tail — it should show the plan status.
      fn _n, request ->
        send(test_pid, {:exec_request, request})
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    ]

    Loop.run("go",
      provider: :mock,
      mock: [responder: scripted(responses)],
      cwd: dir,
      memory: false,
      max_iterations: 8,
      tools: [ExAthena.Tools.TodoWrite, ExAthena.Tools.SpawnAgent],
      mode: :orchestrate,
      assigns: %{
        spawn_agent_opts: [
          provider: :mock,
          mock: [text: "no blog directory exists; services live in web/priv/services"],
          tools: [],
          memory: false
        ]
      }
    )

    assert_receive {:exec_request, request}

    tail =
      request.messages |> Enum.map(& &1.content) |> Enum.filter(&is_binary/1) |> Enum.join("\n")

    assert tail =~ "Plan status"
    # Completed todo shown with its worker's finding.
    assert tail =~ "explore structure"
    assert tail =~ "no blog directory"
    # The next pending item is flagged.
    assert tail =~ "write the post"
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
