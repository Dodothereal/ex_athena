defmodule ExAthena.Modes.Reflexion do
  @moduledoc """
  Reflexion mode: after each ReAct iteration, insert a short self-critique
  pass before the next turn.

  Per the Reflexion paper (Shinn et al.) — and validated in the research
  phase of v0.3 — self-critique is most useful when capped at **3
  reflection cycles**. Beyond that, models exhibit degeneration-of-thought
  (looping on the same critique or contradicting themselves).

  ## How it works

  Each ReAct iteration calls the provider. On `{:continue, state}` return,
  this mode injects a synthetic user message with a reflection prompt,
  lets the model critique its own last turn, and adds the critique to
  history before the next iteration.

  Skips reflection when:
    * Iteration count ≥ `:max_reflections` (default 3, hard cap at 3).
    * The ReAct turn halted (we're terminating anyway).

  ## State

  `state.mode_state[:reflections]` counts performed reflections.

  ## Trade-off

  Reflexion roughly triples per-loop cost (one extra inference per turn
  for the critique). Best reserved for tasks where correctness matters
  more than speed — research-style fact-checking, structured extraction
  at the edge of the model's ability, etc.
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.{Budget, Messages}
  alias ExAthena.Loop.State

  @default_max_reflections 3
  @hard_cap 3

  @reflection_prompt """
  Reflect on your last step. In 1-3 sentences:

  - Did it advance the goal?
  - Did you make any mistakes that will bias the next step?
  - If so, what correction should you take next?

  Keep this terse — the next turn will act on your reflection.
  """

  @impl ExAthena.Loop.Mode
  def init(%State{} = state) do
    max_reflections =
      state.meta
      |> Map.get(:max_reflections, @default_max_reflections)
      |> min(@hard_cap)

    mode_state = %{reflections: 0, max_reflections: max_reflections}
    {:ok, %{state | mode_state: mode_state}}
  end

  @impl ExAthena.Loop.Mode
  def iterate(%State{mode_state: mode_state} = state) do
    case ExAthena.Modes.ReAct.iterate(state) do
      {:continue, new_state} ->
        if should_reflect?(mode_state) do
          case reflect(new_state) do
            {:ok, reflected_state} ->
              new_mode_state = %{
                mode_state
                | reflections: mode_state.reflections + 1
              }

              {:continue, %{reflected_state | mode_state: new_mode_state}}

            {:error, _reason} ->
              # Reflection failures are non-fatal — just skip and continue.
              {:continue, new_state}
          end
        else
          {:continue, new_state}
        end

      other ->
        other
    end
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp should_reflect?(%{reflections: n, max_reflections: m}), do: n < m
  defp should_reflect?(_), do: false

  defp reflect(state) do
    messages = state.messages ++ [Messages.user(@reflection_prompt)]

    request = %{
      state.request_template
      | messages: messages,
        tools: nil,
        max_tokens: 256
    }

    case state.provider_mod.query(request, state.provider_opts) do
      {:ok, response} ->
        new_budget =
          Budget.add(
            state.budget || Budget.new(),
            response.usage,
            extract_cost(response.usage)
          )

        critique = response.text || ""

        new_messages =
          state.messages ++
            [
              Messages.user(@reflection_prompt),
              Messages.assistant(critique)
            ]

        if is_binary(response.thinking) and response.thinking != "" do
          ExAthena.Loop.Events.emit(state.on_event, {:thinking, response.thinking})
        end

        ExAthena.Loop.Events.emit(state.on_event, {:content, critique})

        {:ok, %{state | messages: new_messages, budget: new_budget}}

      {:error, _} = err ->
        err
    end
  end

  defp extract_cost(nil), do: nil

  defp extract_cost(usage) when is_map(usage) do
    Map.get(usage, :total_cost) || Map.get(usage, "total_cost")
  end

  defp extract_cost(_), do: nil
end
