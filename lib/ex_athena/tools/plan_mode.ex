defmodule ExAthena.Tools.PlanMode do
  @moduledoc """
  Toggle the loop's permission phase.

  The loop treats `ctx.phase` as the canonical permission mode. This tool is
  how the model requests a transition:

    * `"enter"` — switch to `:plan` (read-only). Loop typically enforces this
      by rejecting mutation tools.
    * `"exit"` — switch to `:default`. When the run was STARTED in `:plan`
      (host-pinned read-only), the permission layer requires `can_use_tool`
      approval before this tool ever executes, and denies the call outright
      when no callback is configured — the model cannot lift a host-imposed
      read-only restriction on its own. When the model itself entered plan
      mode from a looser phase, exiting merely restores the original grant
      and needs no approval. See `ExAthena.Permissions`.

  The tool doesn't mutate `ctx` directly — `ctx` is immutable per-call. It
  returns a `{:phase_transition, new_phase}` sentinel that the loop consumes
  and applies to subsequent iterations.
  """

  @behaviour ExAthena.Tool

  @impl true
  def name, do: "plan_mode"

  @impl true
  def description,
    do: "Request a transition between plan (read-only) and default (read+write) phases."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: ["enter", "exit"]},
        reason: %{type: "string"}
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "enter"} = args, _ctx) do
    reason = Map.get(args, "reason", "")
    {:ok, %{phase_transition: :plan, reason: reason, message: "entered plan mode"}}
  end

  def execute(%{"action" => "exit"} = args, _ctx) do
    reason = Map.get(args, "reason", "")
    {:ok, %{phase_transition: :default, reason: reason, message: "exited plan mode"}}
  end

  def execute(_, _), do: {:error, :invalid_action}
end
