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

  alias ExAthena.Loop.{Events, State}
  alias ExAthena.RequestQueue

  @planning_addendum """
  ## Planning step
  This is a PLANNING-ONLY turn — tools are unavailable.
  Break the task into a short numbered list of concrete steps. Each step
  should be small and self-contained enough to hand to a focused sub-agent
  that cannot see this conversation. After this turn you will record the
  steps with todo_write and work through them.
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

  # The orchestrator gets coordination + read-only investigation tools ONLY
  # (LangGraph supervisor rule: no specialist tools on the supervisor).
  # Mutating/specialist work (bash, write, edit, patch, lsp, web) belongs to
  # workers — this is what stops small local models from burning their
  # iterations on direct exploration instead of delegating. It also shrinks
  # the tool-schema prompt for weak models.
  @orchestrator_tools ~w(todo_write spawn_agent finish ask_user read glob grep plan_mode)

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
       | mode_state: %{phase: :planning},
         max_concurrency: min(state.max_concurrency, slot_cap(state)),
         tool_specs: Enum.filter(state.tool_specs, &(&1.name in @orchestrator_tools)),
         ctx: %{state.ctx | assigns: assigns},
         request_template: request_template
     }}
  end

  @impl true
  def productivity_signal(prev_state, new_state),
    do: ExAthena.Modes.ReAct.productivity_signal(prev_state, new_state)

  @impl true
  def iterate(%State{mode_state: %{phase: :planning}} = state) do
    request = %{
      state.request_template
      | messages: state.messages,
        tools: nil,
        system_prompt:
          append_prompt(state.request_template.system_prompt, String.trim(@planning_addendum))
    }

    queued_query = fn ->
      RequestQueue.with_slot(
        state.meta[:provider_atom],
        fn -> state.provider_mod.query(request, state.provider_opts) end,
        Keyword.merge(
          state.meta[:queue_opts] || [],
          on_wait: Events.queue_wait_emitter(state.on_event, state.meta[:provider_atom])
        )
      )
    end

    case queued_query.() do
      {:ok, response} ->
        if is_binary(response.thinking) and response.thinking != "" do
          Events.emit(state.on_event, {:thinking, response.thinking})
        end

        Events.emit(state.on_event, {:content, response.text || ""})

        state = fold_usage(state, response)
        new_messages = state.messages ++ [ExAthena.Messages.assistant(response.text || "")]

        {:continue, %{state | messages: new_messages, mode_state: %{phase: :executing}}}

      {:error, %ExAthena.Error{kind: :context_length_exceeded}} ->
        {:error, :error_prompt_too_long}

      {:error, reason} ->
        {:error, {:orchestrate_planning_failed, reason}}
    end
  end

  def iterate(%State{mode_state: %{phase: :executing}} = state) do
    ExAthena.Modes.ReAct.iterate(state)
  end

  def iterate(%State{} = state) do
    ExAthena.Modes.ReAct.iterate(state)
  end

  # ── Internal ──────────────────────────────────────────────────────

  # Fan-out can never exceed what the provider actually serves concurrently.
  defp slot_cap(%State{meta: %{provider_atom: atom}}) when is_atom(atom) and not is_nil(atom),
    do: ExAthena.Config.request_queue_max_depth(atom)

  defp slot_cap(_state), do: 4

  defp append_prompt(nil, addendum), do: addendum
  defp append_prompt("", addendum), do: addendum
  defp append_prompt(existing, addendum), do: existing <> "\n\n" <> addendum

  defp fold_usage(state, response) do
    budget = state.budget || ExAthena.Budget.new()
    cost = extract_cost(response.usage)

    if response.usage do
      Events.emit(state.on_event, {:usage, response.usage})
    end

    %{state | budget: ExAthena.Budget.add(budget, response.usage, cost)}
  end

  defp extract_cost(nil), do: nil

  defp extract_cost(usage) when is_map(usage) do
    Map.get(usage, :total_cost) || Map.get(usage, "total_cost")
  end

  defp extract_cost(_), do: nil
end
