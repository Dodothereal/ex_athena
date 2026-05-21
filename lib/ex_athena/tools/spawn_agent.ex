defmodule ExAthena.Tools.SpawnAgent do
  @moduledoc """
  Synchronously run a sub-agent-loop with its own prompt, tools, and budget.

  Useful for delegating a bounded task (exploring a codebase, summarising a
  file) to a fresh conversation with its own message history — so the parent
  loop doesn't pay the token cost of the sub-task's intermediate steps.

  Arguments:

    * `prompt` (required) — the sub-agent's opening message.
    * `agent` (optional) — name of an `ExAthena.Agents` definition (e.g.
      `"explore"`). The definition's `model`, `provider`, `tools`,
      `permissions`, `mode`, `isolation`, and system-prompt body apply
      automatically; explicit args still override.
    * `tools` (optional) — list of tool names to expose to the sub-agent; defaults
      to whatever the parent had (minus PlanMode + SpawnAgent to avoid loops).
    * `max_iterations` (optional, default 10) — cap on agent-loop iterations.
    * `system_prompt` (optional) — system prompt override for the sub-agent.
    * `cwd` (optional) — working directory for the sub-agent. Defaults to the
      parent's cwd. Useful when delegating work on a different project so the
      sub-agent loads the correct `AGENTS.md` and operates in the right tree.

  Inherits the parent's provider / model / permissions unless overridden in
  `ctx.assigns[:spawn_agent_opts]`.

  ## Worktree isolation

  When the chosen agent definition declares `isolation: :worktree` and the
  parent's cwd is a clean git repo with `git` on PATH, the subagent runs
  in a freshly-created worktree under `~/.cache/ex_athena/worktrees/<sess>/<name>-<n>`.
  If safety checks fail, the subagent transparently falls back to
  `:in_process` — no error.
  """

  alias ExAthena.Agents
  alias ExAthena.Agents.{Sidechain, Worktree}

  @behaviour ExAthena.Tool

  @default_max_iterations 10

  @impl true
  def name, do: "spawn_agent"

  @impl true
  def description,
    do:
      "Run a synchronous sub-agent with its own fresh conversation to accomplish a focused sub-task. Returns the sub-agent's final text."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        prompt: %{type: "string"},
        agent: %{
          type: "string",
          description: "Name of an agent definition (e.g. \"explore\", \"plan\"). Optional."
        },
        tools: %{type: "array", items: %{type: "string"}},
        max_iterations: %{type: "integer"},
        system_prompt: %{type: "string"},
        cwd: %{
          type: "string",
          description:
            "Working directory for the sub-agent. Defaults to the parent's cwd. Use this to point the sub-agent at a different project directory."
        }
      },
      required: ["prompt"]
    }
  end

  @impl true
  def execute(%{"prompt" => prompt} = args, ctx) when is_binary(prompt) do
    timeout = Map.get(args, "timeout_ms", 300_000)

    {agent_def, base_opts} = resolve_agent(args, ctx)

    sub_opts =
      base_opts
      |> Keyword.put_new(
        :max_iterations,
        Map.get(args, "max_iterations", @default_max_iterations)
      )
      |> maybe_put(:system_prompt, Map.get(args, "system_prompt"))
      |> maybe_put(:tools, resolve_tools(Map.get(args, "tools"), ctx))
      |> Keyword.put(:assigns, ctx.assigns)
      |> Keyword.put(:parent_session_id, ctx.session_id)

    # Worktree isolation lives between resolving the agent and starting the
    # sub-loop so the sub-loop's `:cwd` becomes the worktree path. Falls back
    # to the parent's cwd transparently if any safety check fails.
    {sub_opts, isolation_info} = apply_isolation(agent_def, sub_opts, ctx)

    sub_id = "subagent_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

    parent_hooks = Map.get(ctx.assigns || %{}, :hooks, %{})

    emit_event(ctx, {:subagent_spawn, %{id: sub_id, prompt: prompt}})

    _ =
      ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStart, %{
        subagent_id: sub_id,
        prompt: prompt,
        parent_session_id: ctx.session_id,
        agent: agent_def && agent_def.name,
        isolation: isolation_info
      })

    ExAthena.Telemetry.event(
      [:ex_athena, :subagent, :spawn],
      %{},
      %{
        subagent_id: sub_id,
        parent_conversation_id: Map.get(ctx.assigns || %{}, :conversation_id)
      }
    )

    # Run the sub-loop under a supervised Task so a crash doesn't bring
    # down the parent, and timeouts are enforceable. Task.Supervisor is
    # started by ExAthena.Application under `ExAthena.Tasks`.
    task =
      Task.Supervisor.async_nolink(ExAthena.Tasks, fn ->
        ExAthena.Loop.run(prompt, sub_opts)
      end)

    raw_result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    # Persist the sidechain transcript (best-effort; never fails the spawn).
    _ =
      Sidechain.write(%{
        cwd: Keyword.get(sub_opts, :cwd, ctx.cwd),
        parent_session_id: ctx.session_id || "unknown",
        subagent_id: sub_id,
        prompt: prompt,
        opts: sub_opts,
        result:
          case raw_result do
            {:ok, r} -> r
            other -> other
          end
      })

    finalized_isolation = finalize_isolation(isolation_info)

    result =
      case raw_result do
        {:ok, {:ok, %{text: text} = sub_result}} ->
          emit_event(ctx, {:subagent_result, %{id: sub_id, text: text || ""}})

          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :ok,
              result: sub_result,
              isolation: finalized_isolation
            })

          ExAthena.Telemetry.event(
            [:ex_athena, :subagent, :stop],
            %{},
            %{subagent_id: sub_id, outcome: :ok}
          )

          ui = subagent_ui(sub_id, sub_result, finalized_isolation)
          {:ok, text || "", ui}

        {:ok, {:error, reason}} ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :error,
              reason: reason,
              isolation: finalized_isolation
            })

          {:error, {:sub_agent_failed, reason}}

        {:exit, reason} ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :crash,
              reason: reason,
              isolation: finalized_isolation
            })

          {:error, {:sub_agent_crashed, reason}}

        nil ->
          _ =
            ExAthena.Hooks.run_lifecycle(parent_hooks, :SubagentStop, %{
              subagent_id: sub_id,
              outcome: :timeout,
              isolation: finalized_isolation
            })

          {:error, {:sub_agent_timeout, timeout}}
      end

    result
  end

  def execute(_, _), do: {:error, :missing_prompt}

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # Pass names through; the loop resolves names → modules. Filter out the
  # meta tools to avoid runaway recursion.
  defp resolve_tools(nil, _ctx), do: nil

  defp resolve_tools(names, _ctx) when is_list(names) do
    names
    |> Enum.reject(&(&1 in ["plan_mode", "spawn_agent"]))
  end

  defp emit_event(%{assigns: %{on_event: callback}}, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end

  defp emit_event(_ctx, _event), do: :ok

  # ── Agent + isolation resolution ──────────────────────────────────

  defp resolve_agent(args, ctx) do
    effective_cwd = Map.get(args, "cwd") || ctx.cwd

    base_opts =
      (ctx.assigns[:spawn_agent_opts] || [])
      |> Keyword.put_new(:cwd, effective_cwd)

    case Map.get(args, "agent") do
      nil ->
        {nil, base_opts}

      name when is_binary(name) ->
        agents = Map.get(ctx.assigns || %{}, :agents) || Agents.discover(ctx.cwd)

        case Agents.fetch(agents, name) do
          {:ok, def} -> {def, Agents.apply_to_opts(def, base_opts)}
          {:error, :not_found} -> {nil, base_opts}
        end
    end
  end

  defp apply_isolation(nil, opts, _ctx), do: {opts, nil}

  defp apply_isolation(def, opts, ctx) do
    case Worktree.resolve(def, ctx.cwd, ctx.session_id || "session") do
      {:worktree, info} ->
        {Keyword.put(opts, :cwd, info.path), {:worktree, info}}

      {:in_process, reason} ->
        {opts, {:in_process, reason}}
    end
  end

  defp finalize_isolation({:worktree, info}) do
    case Worktree.finalize(info) do
      {:kept, kept} -> {:worktree_kept, kept}
      {:removed, removed} -> {:worktree_removed, removed}
      {:error, reason} -> {:worktree_error, Map.put(info, :reason, reason)}
    end
  end

  defp finalize_isolation(other), do: other

  defp subagent_ui(sub_id, sub_result, isolation) do
    payload = %{
      subagent_id: sub_id,
      iterations: Map.get(sub_result, :iterations),
      tool_calls_made: Map.get(sub_result, :tool_calls_made),
      cost_usd: Map.get(sub_result, :cost_usd),
      duration_ms: Map.get(sub_result, :duration_ms),
      isolation: isolation
    }

    %{kind: :subagent, payload: payload}
  end
end
