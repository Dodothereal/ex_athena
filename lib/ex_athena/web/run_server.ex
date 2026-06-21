defmodule ExAthena.Web.RunServer do
  @moduledoc """
  Per-session owner of one in-flight agent run, decoupled from the LiveView.

  The web run used to be a bare `Task` that sent events straight to the
  LiveView pid captured when the run started. A websocket reconnect spawns a
  *new* LiveView process (new pid), so the in-flight run kept sending to a dead
  process — the user saw streaming freeze and had to reopen the session.

  `RunServer` fixes that by owning the run itself. It is named by the **stable
  session id** (`{:via, Registry, ...}`), survives LiveView reconnects, and:

    * owns the run `Task` and accumulates just enough live state to re-render a
      mid-run view (`stream_text`, `current_action`, a paused `ask_user`
      question, the `streaming?` flag);
    * lets any number of LiveViews `attach/2` — subscribe-then-snapshot in one
      call, then receive the **same** `{:athena, _}` / `{:athena_done, _}` /
      `{:athena_error, _}` / `{:athena_ask_user, _}` messages the LiveView's
      existing `handle_info` clauses already expect;
    * routes a user's `ask_user` answer back into the blocked run via the
      stable channel (`answer/3`), so the reply survives a reconnect;
    * durably persists the final answer (`Sessions.persist_run_result/3`) the
      moment the run finishes — works even with **zero** LiveViews attached.

  ## Supervision & naming

  Started on demand under `ExAthena.Web.RunSupervisor` (a `DynamicSupervisor`)
  with `restart: :temporary`, named
  `{:via, Registry, {ExAthena.Web.RunRegistry, session_id}}`. Both the registry
  and supervisor are started by the `mix athena.web` task (web-only).

  Mirrors the `ExAthena.Orchestrator.Coordinator` pattern; `subscribe`/snapshot
  fan-out is plain `send/2` (host-agnostic — no `Phoenix.PubSub` dependency).
  """

  use GenServer, restart: :temporary

  alias ExAthena.Web.Sessions

  @registry ExAthena.Web.RunRegistry
  @supervisor ExAthena.Web.RunSupervisor

  # Keep the finished server alive briefly so a reconnect landing right after
  # completion can still see the (non-streaming) snapshot before it retires.
  @grace_ms 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a run for `session_id`. Any previous (finished, lingering) server for
  the same session is replaced. `spec` carries:

    * `:run_opts` — keyword list passed to `ExAthena.run/2`, **without** the
      pid-bound keys (`:on_event`, `:assigns`, `:coordinator`) — RunServer
      injects those so they target the stable server, not the LiveView.
    * `:assistant_msg_id` — id of the assistant turn (for durable persistence).
    * `:run_sid` — the orchestration/Overview scope id (echoed in snapshots).
    * `:coordinator` — optional Coordinator pid for the Overview tab.
  """
  @spec start_run(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_run(session_id, spec) do
    case whereis(session_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, Map.put(spec, :session_id, session_id)}
    )
  end

  @doc "Pid of the run server for `session_id`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Whether a run for `session_id` is currently in flight (still streaming)."
  @spec running?(String.t()) :: boolean()
  def running?(session_id) do
    case whereis(session_id) do
      nil -> false
      pid -> GenServer.call(pid, :running?)
    end
  end

  @doc """
  Attach `pid` to the live run for `session_id`. Subscribe-then-snapshot in one
  call (no event can fall between). Returns `{:ok, snapshot}` only while the run
  is still streaming; once finished there is nothing live to attach to and the
  caller should load the (durably persisted) session instead.
  """
  @spec attach(String.t(), pid()) :: {:ok, map()} | {:error, :not_running}
  def attach(session_id, pid) do
    case whereis(session_id) do
      nil -> {:error, :not_running}
      server -> GenServer.call(server, {:attach, pid})
    end
  end

  @doc "Route a user's `ask_user` answer back into the blocked run."
  @spec answer(String.t(), String.t(), String.t()) :: :ok
  def answer(session_id, tool_call_id, answer) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:answer, tool_call_id, answer})
    end
  end

  @doc "Stop the in-flight run for `session_id` (user hit stop)."
  @spec stop_run(String.t()) :: :ok
  def stop_run(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :stop_run)
    end
  end

  # ---------------------------------------------------------------------------
  # Process plumbing
  # ---------------------------------------------------------------------------

  def start_link(spec) do
    GenServer.start_link(__MODULE__, spec, name: via(Map.fetch!(spec, :session_id)))
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(spec) do
    # Register the starting LiveView as a subscriber up front (before the run
    # task is spawned in handle_continue) so no early event can race ahead of
    # the subscription.
    subscribers =
      case Map.get(spec, :subscriber) do
        pid when is_pid(pid) -> %{pid => Process.monitor(pid)}
        _ -> %{}
      end

    state = %{
      session_id: Map.fetch!(spec, :session_id),
      assistant_msg_id: Map.fetch!(spec, :assistant_msg_id),
      run_sid: Map.get(spec, :run_sid),
      coordinator: Map.get(spec, :coordinator),
      run_opts: Map.fetch!(spec, :run_opts),
      task_pid: nil,
      task_ref: nil,
      subscribers: subscribers,
      streaming: true,
      stream_text: "",
      current_action: nil,
      awaiting_question: nil
    }

    {:ok, state, {:continue, :start_run}}
  end

  @impl GenServer
  def handle_continue(:start_run, state) do
    server = self()

    opts =
      state.run_opts
      |> Keyword.put(:on_event, fn event -> send(server, {:run_event, event}) end)
      |> Keyword.put(:assigns, %{ask_user: server})
      |> put_coordinator(state.coordinator)

    {:ok, task_pid} =
      Task.start(fn ->
        case ExAthena.run(nil, opts) do
          {:ok, result} -> send(server, {:run_done, result})
          {:error, reason} -> send(server, {:run_error, reason})
        end
      end)

    ref = Process.monitor(task_pid)
    {:noreply, %{state | task_pid: task_pid, task_ref: ref}}
  end

  defp put_coordinator(opts, nil), do: opts
  defp put_coordinator(opts, coordinator), do: Keyword.put(opts, :coordinator, coordinator)

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, state.streaming, state}

  @impl GenServer
  def handle_call({:attach, pid}, _from, state) do
    if state.streaming do
      ref = Process.monitor(pid)
      state = %{state | subscribers: Map.put(state.subscribers, pid, ref)}
      {:reply, {:ok, snapshot(state)}, state}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  @impl GenServer
  def handle_cast({:answer, tool_call_id, answer}, state) do
    if state.task_pid, do: send(state.task_pid, {:athena_user_answer, tool_call_id, answer})
    {:noreply, %{state | awaiting_question: nil, current_action: "thinking…"}}
  end

  @impl GenServer
  def handle_cast(:stop_run, state) do
    if state.task_pid, do: Process.exit(state.task_pid, :kill)
    {:stop, :normal, %{state | streaming: false}}
  end

  # --- Run → server events (accumulate + fan out unchanged to subscribers) ---

  @impl GenServer
  def handle_info({:run_event, event}, state) do
    state = accumulate(state, event)
    broadcast(state, {:athena, event})
    {:noreply, state}
  end

  # The `ask_user` tool sends here (its pid is this server). Hold the question
  # so a reconnect mid-pause re-surfaces it, then fan it out.
  @impl GenServer
  def handle_info({:athena_ask_user, question}, state) do
    state = %{state | awaiting_question: question, current_action: nil}
    broadcast(state, {:athena_ask_user, question})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:run_done, result}, state) do
    # Durable first: persist regardless of whether any LiveView is attached.
    Sessions.persist_run_result(state.session_id, state.assistant_msg_id, result)
    broadcast(state, {:athena_done, result})
    {:noreply, finish(state)}
  end

  @impl GenServer
  def handle_info({:run_error, reason}, state) do
    broadcast(state, {:athena_error, reason})
    {:noreply, finish(state)}
  end

  @impl GenServer
  def handle_info(:retire, state), do: {:stop, :normal, state}

  # Run task crashed without sending {:run_done,...}/{:run_error,...} — surface
  # it as an error so attached LiveViews reset, then retire.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state = %{state | task_ref: nil, task_pid: nil}

    if state.streaming and reason not in [:normal, :killed] do
      broadcast(state, {:athena_error, {:crashed, reason}})
      {:noreply, finish(state)}
    else
      {:noreply, state}
    end
  end

  # A subscriber (LiveView) went away. Drop it but keep running — the whole
  # point is that the run continues with no UI attached.
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp broadcast(state, message) do
    for {pid, _ref} <- state.subscribers, do: send(pid, message)
    :ok
  end

  defp finish(state) do
    Process.send_after(self(), :retire, @grace_ms)
    %{state | streaming: false, current_action: nil, awaiting_question: nil}
  end

  # Accumulate only what a reconnecting client needs to re-render mid-run; the
  # full details stream is rebuilt from the persisted session on completion.
  defp accumulate(state, {:content, text}) when is_binary(text) do
    %{state | stream_text: state.stream_text <> text}
  end

  defp accumulate(state, {:tool_call, tc}) do
    name = tool_name(tc)
    %{state | current_action: name && "running #{name}…"}
  end

  defp accumulate(state, _event), do: state

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(_), do: nil

  defp snapshot(state) do
    %{
      streaming: state.streaming,
      stream_text: state.stream_text,
      current_action: state.current_action,
      awaiting_question: state.awaiting_question,
      pending_assistant_msg_id: state.assistant_msg_id,
      run_sid: state.run_sid
    }
  end
end
