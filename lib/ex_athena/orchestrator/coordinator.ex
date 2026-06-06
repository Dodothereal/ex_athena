defmodule ExAthena.Orchestrator.Coordinator do
  @moduledoc """
  Per-run orchestration blackboard.

  One Coordinator GenServer observes one top-level run: it ingests loop
  events for the main agent and every subagent (attributed via
  `notify/3`), folds them through the pure `AgentInfo` reducers, and
  broadcasts batched snapshots to subscribed hosts. It is **observational
  only** — control flow stays in the agent loop:

    * All loop → coordinator traffic is `cast`; a coordinator crash can
      never stall or kill a run.
    * Runs never read coordinator state; hosts do, via `snapshot/1` /
      `subscribe/2` (a real call API — never `:sys.get_state/1`).

  ## Supervision & naming

  Started on demand under `ExAthena.Orchestrator.Supervisor`
  (DynamicSupervisor) with `restart: :temporary`, named
  `{:via, Registry, {ExAthena.Orchestrator.Registry, session_id}}`.

  ## Subscribers & batching

  Subscribers are monitored pids receiving
  `{:orchestrator_update, session_id, snapshot}` via plain `send/2`
  (Phoenix.PubSub only exists under `mix athena.web`; send keeps the
  coordinator host-agnostic). Event ingest marks the state dirty and
  arms a 100 ms flush timer — hosts see at most ~10 snapshots/s no matter
  how fast deltas arrive (per-delta fan-out freezes LiveView sockets).

  ## Run lifecycle

  `attach_run/2` monitors the run process: on `:DOWN`, every non-terminal
  agent is marked `:failed` and a retention timer starts (default 5 min)
  so hosts can still inspect the final snapshot before the coordinator
  retires with `:normal`.
  """

  use GenServer, restart: :temporary

  alias ExAthena.Orchestrator.AgentInfo

  @flush_ms 100
  @default_retention_ms 5 * 60 * 1000
  @registry ExAthena.Orchestrator.Registry
  @supervisor ExAthena.Orchestrator.Supervisor

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc "Start (or return) the coordinator for `session_id`."
  @spec start_for(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_for(session_id, opts \\ []) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {__MODULE__, [session_id: session_id] ++ opts}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Pid of the coordinator for `session_id`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Ingest one event for `agent_id` (`:main` or a subagent id). Fire-and-forget
  cast — safe to call against a dead coordinator.

  Besides `ExAthena.Loop.Events` tuples, two coordinator-internal shapes are
  accepted: `{:todos, list}` (todo-list rewrite from a `todo_writer`
  side-channel) and `{:agent_meta, %{prompt:, name:, linked_todo_id:}}`
  (enrichment emitted by SpawnAgent before the subagent runs).
  """
  @spec notify(pid() | String.t(), term(), term()) :: :ok
  def notify(coordinator, agent_id, event) do
    case resolve(coordinator) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:notify, agent_id, event})
    end
  end

  @doc "Monitor the run process so agent statuses track its fate."
  @spec attach_run(pid() | String.t(), pid()) :: :ok | {:error, :not_found}
  def attach_run(coordinator, run_pid) do
    case resolve(coordinator) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:attach_run, run_pid})
    end
  end

  @doc "Current snapshot of the run's observable state."
  @spec snapshot(pid() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(coordinator) do
    case resolve(coordinator) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :snapshot)}
    end
  end

  @doc """
  Subscribe `pid` to batched `{:orchestrator_update, session_id, snapshot}`
  messages. Subscribe-then-snapshot in one call, so no update can fall in
  between. The subscriber is monitored and dropped on exit.
  """
  @spec subscribe(pid() | String.t(), pid()) :: {:ok, map()} | {:error, :not_found}
  def subscribe(coordinator, subscriber_pid) do
    case resolve(coordinator) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, {:subscribe, subscriber_pid})}
    end
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(session_id) when is_binary(session_id), do: whereis(session_id)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      retention_ms: Keyword.get(opts, :retention_ms, @default_retention_ms),
      run_ref: nil,
      main: AgentInfo.new(:main, %{name: "main"}),
      agents: %{},
      order: [],
      # Enrichment that can arrive before the agent entry exists.
      pending_meta: %{},
      subscribers: %{},
      flush_timer: nil,
      dirty?: false
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:notify, agent_id, event}, state) do
    {:noreply, state |> ingest(agent_id, event) |> mark_dirty()}
  end

  @impl GenServer
  def handle_call({:attach_run, run_pid}, _from, state) do
    ref = Process.monitor(run_pid)
    {:reply, :ok, %{state | run_ref: ref}}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = %{state | subscribers: Map.put(state.subscribers, pid, ref)}
    {:reply, build_snapshot(state), state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}

    if state.dirty? do
      snapshot = build_snapshot(state)

      for {pid, _ref} <- state.subscribers do
        send(pid, {:orchestrator_update, state.session_id, snapshot})
      end

      {:noreply, %{state | dirty?: false}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:retire, state), do: {:stop, :normal, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{run_ref: ref} = state) do
    # The run died (or finished): fail anything still in flight, keep the
    # snapshot viewable for the retention window, then retire.
    state = %{
      state
      | main: AgentInfo.fail(state.main),
        agents: Map.new(state.agents, fn {id, info} -> {id, AgentInfo.fail(info)} end),
        run_ref: nil
    }

    Process.send_after(self(), :retire, state.retention_ms)
    {:noreply, mark_dirty(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  # ---------------------------------------------------------------------------
  # Ingest
  # ---------------------------------------------------------------------------

  # Boundary events from the main loop open/close subagent entries.
  defp ingest(state, :main, {:subagent_spawn, %{id: sub_id} = payload}) do
    state
    |> ensure_agent(sub_id, %{prompt_summary: payload[:prompt]})
    |> update_main(&AgentInfo.apply_event(&1, {:subagent_spawn, payload}))
  end

  defp ingest(state, :main, {:subagent_result, %{id: sub_id} = payload}) do
    state
    |> close_agent(sub_id, payload[:text])
    |> update_main(&AgentInfo.apply_event(&1, {:subagent_result, payload}))
  end

  defp ingest(state, :main, event) do
    update_main(state, &AgentInfo.apply_event(&1, event))
  end

  # Enrichment from SpawnAgent — may arrive before or after the boundary
  # spawn event; ensure_agent + merge covers both orders.
  defp ingest(state, sub_id, {:agent_meta, meta}) do
    if Map.has_key?(state.agents, sub_id) do
      update_agent(state, sub_id, fn info ->
        %{
          info
          | name: meta[:name] || info.name,
            prompt_summary: info.prompt_summary || meta[:prompt],
            linked_todo:
              meta[:linked_todo] || info.linked_todo ||
                fuzzy_todo_match(meta[:prompt], state.main.todos)
        }
      end)
    else
      %{state | pending_meta: Map.put(state.pending_meta, sub_id, meta)}
    end
  end

  defp ingest(state, sub_id, event) do
    state
    |> ensure_agent(sub_id, %{})
    |> update_agent(sub_id, &AgentInfo.apply_event(&1, event))
  end

  defp ensure_agent(state, sub_id, attrs) do
    if Map.has_key?(state.agents, sub_id) do
      state
    else
      {meta, pending} = Map.pop(state.pending_meta, sub_id, %{})
      # The meta prompt (SpawnAgent's raw task text) is the richer matching
      # source; the boundary event's prompt may be abbreviated.
      match_prompt = meta[:prompt] || attrs[:prompt_summary]

      info =
        AgentInfo.new(sub_id, %{
          name: meta[:name],
          prompt_summary: attrs[:prompt_summary] || meta[:prompt],
          # Models often omit the explicit `todo:` link — fall back to
          # fuzzy-matching the worker's prompt against the task list so the
          # Overview tree groups it under its parent task and runtime todo
          # completion still works.
          linked_todo: meta[:linked_todo] || fuzzy_todo_match(match_prompt, state.main.todos)
        })

      %{
        state
        | agents: Map.put(state.agents, sub_id, info),
          order: state.order ++ [sub_id],
          pending_meta: pending
      }
    end
  end

  # A finished subagent: mark done, keep its final summary (its contribution
  # to the parent task), and auto-complete the main todo it was linked to
  # (runtime-derived completion — never trust model bookkeeping).
  defp close_agent(state, sub_id, text) do
    state = ensure_agent(state, sub_id, %{})
    info = state.agents[sub_id]

    closed =
      info
      |> AgentInfo.apply_event({:done, %ExAthena.Result{finish_reason: :stop}})
      |> maybe_put_result(text)

    state = %{state | agents: Map.put(state.agents, sub_id, closed)}

    case closed do
      %{linked_todo: content} when is_binary(content) ->
        update_main(state, &AgentInfo.complete_todo_by_content(&1, content))

      _ ->
        state
    end
  end

  defp maybe_put_result(info, text) when is_binary(text) and text != "",
    do: AgentInfo.apply_event(info, {:result_note, text})

  defp maybe_put_result(info, _text), do: info

  defp update_main(state, fun), do: %{state | main: fun.(state.main)}

  # Best word-overlap match between a worker's prompt and the task list:
  # score = |significant words ∩| / |todo's significant words|, threshold ½.
  defp fuzzy_todo_match(prompt, todos) when is_binary(prompt) and todos != [] do
    prompt_words = significant_words(prompt)

    todos
    |> Enum.map(fn todo ->
      todo_words = significant_words(todo.content)

      score =
        case MapSet.size(todo_words) do
          0 -> 0.0
          n -> MapSet.size(MapSet.intersection(todo_words, prompt_words)) / n
        end

      {todo.content, score}
    end)
    |> Enum.max_by(fn {_content, score} -> score end, fn -> {nil, 0.0} end)
    |> case do
      {content, score} when score >= 0.5 -> content
      _ -> nil
    end
  end

  defp fuzzy_todo_match(_prompt, _todos), do: nil

  defp significant_words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.filter(&(String.length(&1) > 3))
    |> MapSet.new()
  end

  defp update_agent(state, sub_id, fun) do
    %{state | agents: Map.update!(state.agents, sub_id, fun)}
  end

  # ---------------------------------------------------------------------------
  # Snapshots & flushing
  # ---------------------------------------------------------------------------

  defp build_snapshot(state) do
    %{
      session_id: state.session_id,
      main: state.main,
      agents: Enum.map(state.order, &Map.fetch!(state.agents, &1))
    }
  end

  defp mark_dirty(%{flush_timer: nil} = state) do
    %{state | dirty?: true, flush_timer: Process.send_after(self(), :flush, @flush_ms)}
  end

  defp mark_dirty(state), do: %{state | dirty?: true}
end
