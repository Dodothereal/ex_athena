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

  # ONE byte-stable protocol for both phases — phase-varying system prompts
  # (and toolsets) break prefix caching on local servers at token ~0.
  # Phase steering rides as an EPHEMERAL tail note instead (meta[:phase_note]).
  @protocol_addendum """
  ## Orchestration protocol
  You are the orchestrator. You NEVER read files, fetch URLs, or run
  commands yourself — delegate ALL exploration and execution to
  spawn_agent workers (agent: "explore" with a focused brief for
  read-only research). Work strictly through your todo list:
  1. FIRST record a draft plan with todo_write (one todo per step) based
     on what you already know — include an "Explore …" todo as step 1
     when investigation is needed. Each todo must be small and
     self-contained enough to hand to a worker that cannot see this
     conversation.
  2. Delegate each substantial step to spawn_agent. Workers cannot see
     this conversation — every spawn needs a self-contained brief
     (objective, expected_output, tool_guidance, boundaries) and `todo:`
     set to the exact todo content the worker handles.
  3. After each worker returns, update todo_write (mark completed, add
     newly discovered steps). ALWAYS send the FULL list — completed items
     included, new todos appended at the end; never drop finished work.
     Record decisions only — never restate worker output verbatim.
  4. Never delegate work that is not on the todo list — FIRST add the
     todo with todo_write, THEN spawn the worker with `todo:` set to it.
     One todo per worker; do not bundle several steps into one spawn.
  5. Effort scaling: one worker for a simple step, two for comparisons.
     Read-only research workers may run in parallel; only ONE worker that
     writes/edits files at a time.
  6. When every todo is completed, call finish with a deliverable
     summarizing the outcome.
  """

  @planning_note """
  [orchestration runtime] PLANNING: no plan is recorded yet — your next
  action should be todo_write with your draft plan (or spawn ONE explore
  worker first if you cannot draft anything). A tool-free numbered plan in
  text also works.\
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

  # Exploration during planning is bounded — after this many planning turns
  # the runtime forces the transition to execution with what is known.
  # (Planning uses the SAME coordination toolset as executing — tool
  # schemas render into the prompt prefix, so phase-varying toolsets break
  # prefix caching.)
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
          append_prompt(state.request_template.system_prompt, String.trim(@protocol_addendum))
    }

    {:ok,
     %{
       state
       | mode_state: %{
           phase: :planning,
           todos: [],
           turns_without_spawn: 0,
           planning_turns: 0
         },
         # Uncapped by design (user-directed): the orchestrator runs until
         # the todos are done. The no-progress guard, mistake counter,
         # budget cap, and the host's stop control bound the run. An
         # explicitly passed cap is honored.
         max_iterations: orchestrator_iterations(state),
         max_concurrency: min(state.max_concurrency, slot_cap(state)),
         tool_specs: Enum.filter(state.tool_specs, &(&1.name in @orchestrator_tools)),
         ctx: %{state.ctx | assigns: assigns},
         # Ephemeral phase steering (request tail, never persisted) —
         # cleared by to_executing/1.
         meta: Map.put(state.meta, :phase_note, String.trim(@planning_note)),
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
    # Planning is plain ReAct with the SAME toolset/system prompt as
    # executing (byte-stable prefix for cache reuse) — only an ephemeral
    # tail note (meta[:phase_note]) steers the phase. Planning ends when
    # the plan exists: a todo_write (the todo list IS the plan) or a
    # tool-free reply.
    prev_count = length(state.messages)

    case ExAthena.Modes.ReAct.iterate(state) do
      {:halt, halted} ->
        if halted.meta[:finish_reason] == :stop do
          # The tool-free plan turn — transition instead of terminating.
          {:continue, to_executing(halted)}
        else
          # Real terminations (errors, finish tool) propagate untouched.
          {:halt, halted}
        end

      {:continue, new_state} ->
        todos = extract_todos(Enum.drop(new_state.messages, prev_count))
        turns = (mode_state[:planning_turns] || 0) + 1

        cond do
          todos != nil ->
            # The model recorded its plan — seed the ledger and execute.
            {:continue, new_state |> put_watch(todos, 0) |> to_executing()}

          turns >= @max_planning_turns ->
            note =
              ExAthena.Messages.user(
                "[orchestration runtime] Planning budget exhausted — proceed to execution " <>
                  "with what you know: record your todos with todo_write and delegate."
              )

            {:continue, %{new_state | messages: new_state.messages ++ [note]} |> to_executing()}

          true ->
            {:continue, put_in(new_state.mode_state[:planning_turns], turns)}
        end

      other ->
        other
    end
  end

  def iterate(%State{mode_state: %{phase: :executing}} = state) do
    prev_count = length(state.messages)

    case ExAthena.Modes.ReAct.iterate(state) do
      {:continue, new_state} ->
        watchdog(new_state, prev_count)

      {:halt, halted} ->
        maybe_nudge_stop(halted)

      other ->
        other
    end
  end

  def iterate(%State{} = state) do
    ExAthena.Modes.ReAct.iterate(state)
  end

  # Small models routinely narrate intent ("I will now create the post")
  # with no tool call — a bare-text :stop with PENDING todos would end the
  # run mid-task as "success". Nudge once; honor the second stop.
  defp maybe_nudge_stop(halted) do
    pending =
      Enum.filter(halted.mode_state[:todos] || [], fn t ->
        field(t, :status) in [nil, "pending", "in_progress"]
      end)

    cond do
      halted.meta[:finish_reason] != :stop or pending == [] ->
        {:halt, halted}

      halted.mode_state[:stop_nudged] ->
        {:halt, halted}

      true ->
        note =
          ExAthena.Messages.user(
            "[orchestration runtime] You stopped with PENDING todos: " <>
              Enum.map_join(pending, "; ", &field(&1, :content)) <>
              ". Delegate the next one with spawn_agent, or call finish if the task is truly done."
          )

        {:continue,
         %{
           halted
           | messages: halted.messages ++ [note],
             mode_state: Map.put(halted.mode_state, :stop_nudged, true),
             meta: Map.delete(halted.meta, :finish_reason)
         }}
    end
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

    todos = extract_todos(new_msgs) || state.mode_state[:todos] || []

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

  # The latest todo_write call's list in a message slice, or nil when none.
  defp extract_todos(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: :assistant, tool_calls: tcs} when is_list(tcs) -> tcs
      _ -> []
    end)
    |> Enum.filter(&(&1.name == "todo_write"))
    |> List.last()
    |> case do
      nil -> nil
      tc -> List.wrap(tc.arguments["todos"])
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

  # Switch phases: clear the stale :stop set by a tool-free plan turn and
  # drop the ephemeral planning tail note.
  defp to_executing(state) do
    %{
      state
      | mode_state: Map.put(state.mode_state, :phase, :executing),
        meta: state.meta |> Map.delete(:finish_reason) |> Map.delete(:phase_note)
    }
  end
end
