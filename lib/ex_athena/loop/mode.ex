defmodule ExAthena.Loop.Mode do
  @moduledoc """
  Pluggable control-flow strategy for the agent loop.

  Modes decide *what to do each turn*. The kernel handles everything else —
  tool dispatch, permissions, hooks, events, accounting. Modes sit on top
  and shape the iteration: ReAct is "infer → tool → loop", Plan-and-Solve
  is "plan once → execute many", Reflexion adds a self-critique pass.

  ## Writing a mode

      defmodule MyMode do
        @behaviour ExAthena.Loop.Mode

        @impl true
        def init(state), do: {:ok, state}

        @impl true
        def iterate(state) do
          # Run inference, handle tool calls, update state, decide continue/halt.
          # Return {:continue, state} to keep looping, {:halt, state} to stop.
          {:continue, state}
        end
      end

  The builtin `ExAthena.Modes.ReAct` is a reference implementation.

  ## Atom shortcuts

  `:react`, `:plan_and_solve`, `:reflexion` resolve to the builtin modules.
  Any other atom or a module reference is used verbatim.
  """

  alias ExAthena.Loop.State

  @doc "Called once before the first iteration. Use to prime mode-specific state."
  @callback init(State.t()) :: {:ok, State.t()} | {:error, term()}

  @doc """
  Drive one iteration. Return one of:

    * `{:continue, State.t()}` — keep looping (kernel checks caps + budget).
    * `{:halt, State.t()}` — stop looping; the kernel produces a `Result`
      from the terminal state's `finish_reason` (which the mode should set
      via `ExAthena.Loop.set_finish_reason/2` before returning).
    * `{:error, reason}` — abort with an unrecoverable error. The kernel
      wraps this in `:error_during_execution`.
  """
  @callback iterate(State.t()) :: {:continue, State.t()} | {:halt, State.t()} | {:error, term()}

  @doc """
  Optional. Called after each `{:continue, new_state}` to determine whether
  the iteration was productive. Return `true` if the run made progress (new
  tool name+args pair OR new assistant text), `false` otherwise. When not
  implemented, the kernel uses its own default check.
  """
  @callback productivity_signal(prev_state :: State.t(), new_state :: State.t()) :: boolean()

  @optional_callbacks [productivity_signal: 2]

  @builtins %{
    react: ExAthena.Modes.ReAct,
    plan_and_solve: ExAthena.Modes.PlanAndSolve,
    reflexion: ExAthena.Modes.Reflexion,
    orchestrate: ExAthena.Modes.Orchestrate
  }

  @doc "Resolve an atom shortcut or module to the Mode module."
  @spec resolve(atom() | module()) :: module()
  def resolve(mode) when is_atom(mode) do
    case Map.fetch(@builtins, mode) do
      {:ok, module} -> module
      :error -> mode
    end
  end
end
