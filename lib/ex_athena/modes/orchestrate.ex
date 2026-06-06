defmodule ExAthena.Modes.Orchestrate do
  @moduledoc """
  Orchestrator mode: plan → todo → delegate each step to a subagent →
  integrate summaries → finish.

  Prompt-driven delegation inside **deterministic runtime rails** — the 2026
  consensus across Claude Code, Anthropic's multi-agent research system,
  OpenAI's manager pattern, and LangGraph's supervisor:

    * **Depth 1** — workers never spawn workers (enforced in SpawnAgent).
    * **Fan-out ≤ provider slots** — `max_concurrency` is capped at the
      provider's request-queue depth, so parallel workers can never exceed
      what the GPU actually serves.
    * **Strict task briefs** — `assigns[:strict_spawn]` makes SpawnAgent
      reject delegation without the four-field brief (objective,
      expected_output, tool_guidance, boundaries).
    * **Summary-only returns** — workers' final messages are the only thing
      entering this context (and the prompt forbids restating them).

  Mechanically it follows the PlanAndSolve shape: one tool-free planning
  iteration, then delegation-driven ReAct. The worker contract rides in as
  `assigns[:subagent_prompt_suffix]` (appended by SpawnAgent to every
  worker's system prompt) unless the caller supplied their own.
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.Loop.State

  @planning_addendum """
  ## Planning phase
  You are PLANNING. Understand the task, then produce the plan:
  - Prefer delegating exploration to a worker: spawn_agent with
    agent: "explore" and a focused brief — it reports back a summary
    without filling your context.
  - Direct read/glob/grep/web_fetch are for QUICK orientation only
    (a file or two), never deep investigation.
  - When you understand enough, reply with ONLY a short numbered plan
    (no tool calls). Each step must be small and self-contained enough to
    hand to a worker that cannot see this conversation. That tool-free
    reply ends planning; you will then record the steps with todo_write
    and delegate them.
  """

  @execution_addendum """
  ## Orchestration protocol
  You are the orchestrator. Work strictly through your todo list:
  1. First, record your plan with todo_write (one todo per step).
  2. Delegate each substantial step to spawn_agent. Workers cannot see this
     conversation — every spawn needs a self-contained brief (objective,
     expected_output, tool_guidance, boundaries) and `todo:` set to the
     exact todo content the worker handles.
  3. After each worker returns, update todo_write (mark completed, add newly
     discovered steps). Record decisions only — never restate worker output
     verbatim.
  4. Effort scaling: one worker for a simple step, two for comparisons.
     Read-only research workers may run in parallel; only ONE worker that
     writes/edits files at a time.
  5. When every todo is completed, call finish with a deliverable
     summarizing the outcome.
  """

  @worker_suffix """
  ## Worker contract
  You are a sub-agent responsible for ONE step of a larger task.
  - Maintain your own todo list with todo_write as you work.
  - End EVERY response with a line: CONCLUSION: <one sentence>.
  - Your FINAL message must be a self-contained summary (max 300 words):
    findings, decisions, files changed. The orchestrator sees only that
    summary.
  """

  # The orchestrator gets coordination tools ONLY — no specialist tools on
  # the supervisor, NO exceptions (LangGraph supervisor rule). Live testing
  # showed even read/glob/grep let a small local model burn every iteration
  # on self-investigation instead of delegating. Any inspection now costs a
  # worker spawn, which is the point. It also shrinks the tool-schema
  # prompt for weak models.
  @orchestrator_tools ~w(todo_write spawn_agent finish ask_user)

  # Planning phase: read-only exploration + delegation — quick peeks are
  # allowed, the prompt pushes exploration AGENTS for anything deeper, and
  # nothing can mutate before a plan exists.
  @planning_tools ~w(read glob grep web_fetch lsp spawn_agent ask_user)

  # Exploration during planning is bounded — after this many planning turns
  # the runtime forces the transition to execution with what is known.
  @max_planning_turns 8

  # Auto-delegation watchdog: with pending todos, after this many
  # consecutive turns without a spawn_agent call the runtime delegates the
  # first pending todo itself (deterministic rail — prompts alone don't
  # bind small models).
  @max_turns_without_spawn 2

  @impl true
  def init(%State{} = state) do
    assigns =
      state.ctx.assigns
      |> Map.put(:strict_spawn, true)
      |> Map.put_new(:subagent_prompt_suffix, String.trim(@worker_suffix))

    request_template = %{
      state.request_template
      | system_prompt:
          append_prompt(state.request_template.system_prompt, String.trim(@execution_addendum))
    }

    {:ok,
     %{
       state
       | mode_state: %{
           phase: :planning,
           todos: [],
           turns_without_spawn: 0,
           planning_turns: 0,
           # Planning swaps these in per turn; executing uses the state's own.
           planning_specs: Enum.filter(state.tool_specs, &(&1.name in @planning_tools))
         },
         # Uncapped by design (user-directed): the orchestrator runs until
         # the todos are done. The no-progress guard, mistake counter,
         # budget cap, and the host's stop control bound the run. An
         # explicitly passed cap is honored.
         max_iterations: orchestrator_iterations(state),
         max_concurrency: min(state.max_concurrency, slot_cap(state)),
         tool_specs: Enum.filter(state.tool_specs, &(&1.name in @orchestrator_tools)),
         ctx: %{state.ctx | assigns: assigns},
         request_template: request_template
     }}
  end

  defp orchestrator_iterations(%State{meta: %{explicit_max_iterations?: true}} = state),
    do: state.max_iterations

  defp orchestrator_iterations(_state), do: :infinity

  @impl true
  def productivity_signal(prev_state, new_state),
    do: ExAthena.Modes.ReAct.productivity_signal(prev_state, new_state)

  @impl true
  def iterate(%State{mode_state: %{phase: :planning} = mode_state} = state) do
    # Planning is itself a (read-only) ReAct phase: the orchestrator may
    # take quick peeks or delegate exploration workers across several
    # turns. A TOOL-FREE reply is the plan and ends the phase; the
    # executing toolset/prompt (set in init) is restored afterwards.
    planning_state = %{
      state
      | tool_specs: mode_state.planning_specs,
        request_template: %{
          state.request_template
          | system_prompt:
              append_prompt(
                state.request_template.system_prompt,
                String.trim(@planning_addendum)
              )
        }
    }

    case ExAthena.Modes.ReAct.iterate(planning_state) do
      {:halt, halted} ->
        if halted.meta[:finish_reason] == :stop do
          # The tool-free plan turn — transition instead of terminating.
          {:continue, halted |> restore_executing(state) |> to_executing()}
        else
          # Real terminations (errors, finish tool) propagate untouched.
          {:halt, restore_executing(halted, state)}
        end

      {:continue, new_state} ->
        new_state = restore_executing(new_state, state)
        turns = (mode_state[:planning_turns] || 0) + 1

        if turns >= @max_planning_turns do
          note =
            ExAthena.Messages.user(
              "[orchestration runtime] Planning budget exhausted — proceed to execution " <>
                "with what you know: record your todos with todo_write and delegate."
            )

          {:continue, %{new_state | messages: new_state.messages ++ [note]} |> to_executing()}
        else
          {:continue, put_in(new_state.mode_state[:planning_turns], turns)}
        end

      other ->
        other
    end
  end

  def iterate(%State{mode_state: %{phase: :executing}} = state) do
    prev_count = length(state.messages)

    case ExAthena.Modes.ReAct.iterate(state) do
      {:continue, new_state} -> watchdog(new_state, prev_count)
      other -> other
    end
  end

  def iterate(%State{} = state) do
    ExAthena.Modes.ReAct.iterate(state)
  end

  # ── Auto-delegation watchdog ──────────────────────────────────────

  # Track the latest todo list and whether the model delegated this turn;
  # after @max_turns_without_spawn spawn-less turns with pending todos, the
  # RUNTIME delegates the first pending todo (jido directive style: the
  # decision stays observable, the effect is executed by code).
  defp watchdog(state, prev_count) do
    new_msgs = Enum.drop(state.messages, prev_count)

    calls =
      Enum.flat_map(new_msgs, fn
        %{role: :assistant, tool_calls: tcs} when is_list(tcs) -> tcs
        _ -> []
      end)

    todos =
      calls
      |> Enum.filter(&(&1.name == "todo_write"))
      |> List.last()
      |> case do
        nil -> state.mode_state[:todos] || []
        tc -> List.wrap(tc.arguments["todos"])
      end

    # Only a SUCCESSFUL spawn counts as delegation — live testing showed a
    # model repeating an invalid spawn call verbatim every turn, which must
    # not keep resetting the watchdog.
    spawn_ids = for tc <- calls, tc.name == "spawn_agent", do: tc.id

    spawned? =
      new_msgs
      |> Enum.flat_map(fn
        %{role: :tool, tool_results: trs} when is_list(trs) -> trs
        _ -> []
      end)
      |> Enum.any?(fn tr -> tr.tool_call_id in spawn_ids and tr.is_error != true end)

    turns = if spawned?, do: 0, else: (state.mode_state[:turns_without_spawn] || 0) + 1

    pending =
      Enum.filter(todos, fn t ->
        field(t, :status) in [nil, "pending", "in_progress"]
      end)

    if pending != [] and turns >= @max_turns_without_spawn do
      state = auto_delegate(state, hd(pending))
      {:continue, put_watch(state, todos, 0)}
    else
      {:continue, put_watch(state, todos, turns)}
    end
  end

  defp put_watch(state, todos, turns) do
    %{
      state
      | mode_state: Map.merge(state.mode_state, %{todos: todos, turns_without_spawn: turns})
    }
  end

  defp auto_delegate(state, todo) do
    content = field(todo, :content) || "the next pending step"

    args = %{
      "prompt" => "Complete this step of a larger task: #{content}",
      "objective" => content,
      "expected_output" =>
        "a self-contained summary (max 300 words) of findings, decisions, and files changed",
      "tool_guidance" =>
        "use any available tools (read, glob, grep, bash, write, edit) as needed",
      "boundaries" => "do only this step; do not start other todos",
      "todo" => content,
      "max_result_chars" => 2_000,
      "timeout_ms" => 1_800_000
    }

    ctx = %{
      state.ctx
      | tool_call_id: "auto_delegate_#{System.unique_integer([:positive])}"
    }

    note =
      case ExAthena.Tools.SpawnAgent.execute(args, ctx) do
        {:ok, text, _ui} ->
          "[orchestration runtime] You did not delegate, so the runtime delegated the " <>
            ~s(pending todo "#{content}" to a worker. Worker summary:\n#{text}\n) <>
            "Update your todo list, then delegate the next pending todo with spawn_agent."

        {:error, reason} ->
          "[orchestration runtime] Auto-delegation of \"#{content}\" failed: " <>
            "#{inspect(reason)}. Revise the plan or delegate it yourself with spawn_agent."
      end

    %{state | messages: state.messages ++ [ExAthena.Messages.user(note)]}
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  # ── Internal ──────────────────────────────────────────────────────

  # Fan-out can never exceed what the provider actually serves concurrently.
  defp slot_cap(%State{meta: %{provider_atom: atom}}) when is_atom(atom) and not is_nil(atom),
    do: ExAthena.Config.request_queue_max_depth(atom)

  defp slot_cap(_state), do: 4

  defp append_prompt(nil, addendum), do: addendum
  defp append_prompt("", addendum), do: addendum
  defp append_prompt(existing, addendum), do: existing <> "\n\n" <> addendum

  # Planning runs ReAct with a swapped toolset/prompt — the executing
  # versions (set in init) are restored on every returned state.
  defp restore_executing(new_state, %State{tool_specs: specs, request_template: template}) do
    %{new_state | tool_specs: specs, request_template: template}
  end

  # The tool-free plan turn set finish_reason :stop — clear it and switch
  # phases so the run continues into execution.
  defp to_executing(state) do
    %{
      state
      | mode_state: Map.put(state.mode_state, :phase, :executing),
        meta: Map.delete(state.meta, :finish_reason)
    }
  end
end
