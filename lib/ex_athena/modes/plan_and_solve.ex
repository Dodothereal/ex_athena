defmodule ExAthena.Modes.PlanAndSolve do
  @moduledoc """
  Plan-and-Solve mode.

  Two-phase operation: on the first iteration, the agent is asked to
  **plan** before it acts. Subsequent iterations execute the plan using
  `ExAthena.Modes.ReAct`'s standard cycle.

  Rationale (Plan-and-Solve literature): models produce better
  tool-calling behaviour when they articulate a plan before diving into
  actions. Forcing the first turn to be planning-only prevents the
  "immediate tool call" failure mode you see with small models on
  complex prompts.

  ## State

  Plan-mode state is kept in `state.mode_state[:phase]`:

    * `:planning` — on the first iteration. A planning-only system-prompt
      addendum is injected, forbidding tool calls.
    * `:executing` — subsequent iterations fall through to the ReAct
      cycle.

  ## Configuration

      ExAthena.run(prompt, mode: :plan_and_solve, …)

  No extra options. The planning system prompt is hardcoded; consumers
  who want a custom planning instruction should implement their own Mode
  (the `ReAct` module is 200 lines of reference).
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.Loop.State

  @planning_addendum """

  ## Planning phase

  Before you take any action, produce a plan. Your response this turn
  MUST be plain text with no tool calls. Structure your plan as:

    1. **Goal** — what is the user asking for?
    2. **Approach** — how will you get there? Which tools will you need,
       in what order?
    3. **Risks** — what could go wrong, and how will you detect + recover?

  Once you finish your plan, wait for the next turn to begin executing.
  """

  @impl ExAthena.Loop.Mode
  def init(%State{} = state) do
    # Start in :planning phase. A planning-addendum is appended to the
    # system prompt; tools are withheld on this iteration.
    {:ok, %{state | mode_state: %{phase: :planning}}}
  end

  @impl ExAthena.Loop.Mode
  def iterate(%State{mode_state: %{phase: :planning}} = state) do
    # Run one inference with planning addendum + no tools. Append plan to
    # messages, transition to :executing, continue.
    request = build_planning_request(state)

    case state.provider_mod.query(request, state.provider_opts) do
      {:ok, response} ->
        if is_binary(response.thinking) and response.thinking != "" do
          ExAthena.Loop.Events.emit(state.on_event, {:thinking, response.thinking})
        end

        ExAthena.Loop.Events.emit(state.on_event, {:content, response.text || ""})

        state = fold_usage(state, response)

        new_messages =
          state.messages ++ [ExAthena.Messages.assistant(response.text || "")]

        {:continue, %{state | messages: new_messages, mode_state: %{phase: :executing}}}

      # Context overflow during planning: surface the kernel's typed capacity
      # signal so it force-compacts the existing context and retries planning,
      # rather than dying as a generic execution error. Mirrors ReAct.
      {:error, %ExAthena.Error{kind: :context_length_exceeded}} ->
        {:error, :error_prompt_too_long}

      {:error, reason} ->
        {:error, {:plan_and_solve_planning_failed, reason}}
    end
  end

  def iterate(%State{mode_state: %{phase: :executing}} = state) do
    # Delegate to ReAct for the remaining iterations.
    ExAthena.Modes.ReAct.iterate(state)
  end

  def iterate(%State{} = state) do
    # No mode state (direct call) — behave like ReAct.
    ExAthena.Modes.ReAct.iterate(state)
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp build_planning_request(state) do
    system_prompt =
      case state.request_template.system_prompt do
        nil -> @planning_addendum
        "" -> @planning_addendum
        str -> str <> @planning_addendum
      end

    %{
      state.request_template
      | messages: state.messages,
        system_prompt: system_prompt,
        # Explicitly no tools this turn — the planning phase is text-only.
        tools: nil
    }
  end

  defp fold_usage(state, response) do
    budget = state.budget || ExAthena.Budget.new()
    cost = extract_cost(response.usage)
    %{state | budget: ExAthena.Budget.add(budget, response.usage, cost)}
  end

  defp extract_cost(nil), do: nil

  defp extract_cost(usage) when is_map(usage) do
    Map.get(usage, :total_cost) || Map.get(usage, "total_cost")
  end

  defp extract_cost(_), do: nil
end
