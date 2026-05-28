defmodule ExAthena.RequestQueue do
  @moduledoc """
  ETS-backed GenServer semaphore that limits concurrent in-flight requests per provider.

  Each provider has an independent slot cap (see `ExAthena.Config.request_queue_max_depth/1`).
  `acquire/2` blocks the caller until a slot is available; `release/1` frees the slot
  and wakes the next queued caller (FIFO). `depth/1` reads the ETS counter directly,
  never blocking the caller.

  The queue is opt-in and disabled by default. When the GenServer is not running
  (feature disabled), `acquire/1` and `release/1` are no-ops returning `:ok`.

  Enable via:

      config :ex_athena, :request_queue, enabled: true

  ## Dead-waiter cleanup

  Every blocked caller is monitored. If a caller process exits before its slot is
  granted, the monitor fires and removes the dead entry from the queue so the
  corresponding slot is correctly freed on the next `release/1`.
  """

  use GenServer

  @table __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a slot for `provider`. Blocks the caller until a slot is available or
  `timeout` milliseconds elapse (default 5 000 ms).

  Returns `:ok` when a slot is granted. When the GenServer is not running
  (feature disabled), returns `:ok` immediately as a no-op.
  """
  @spec acquire(atom(), non_neg_integer()) :: :ok
  def acquire(provider, timeout \\ 5_000) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:acquire, provider}, timeout)
    end
  end

  @doc """
  Release a previously acquired slot for `provider`. Returns `:ok`.

  If callers are queued for this provider, the next one in line is unblocked
  and inherits the slot (depth stays unchanged). When the GenServer is not
  running, returns `:ok` immediately as a no-op.
  """
  @spec release(atom()) :: :ok
  def release(provider) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:release, provider})
    end
  end

  @doc """
  Return the number of active (acquired) slots for `provider`.

  Reads directly from the ETS table; never blocks the caller and never goes
  through the GenServer mailbox. Returns `0` when the queue is disabled (ETS
  table does not exist).
  """
  @spec depth(atom()) :: non_neg_integer()
  def depth(provider) do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _ ->
        case :ets.lookup(@table, provider) do
          [{^provider, count}] -> count
          [] -> 0
        end
    end
  end

  @doc """
  Cancel any pending acquire for the calling process on `provider`.

  Called automatically by the entry-point helpers when a `GenServer.call`
  timeout fires so that stale waiting entries do not prevent depth from
  decrementing on the next `release/1`.
  """
  @spec cancel_acquire(atom()) :: :ok
  def cancel_acquire(provider) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:cancel_acquire, provider, self()})
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{waiting: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, provider}, from, state) do
    max = ExAthena.Config.request_queue_max_depth(provider)
    current = depth(provider)

    if current < max do
      :ets.insert(@table, {provider, current + 1})
      {:reply, :ok, state}
    else
      {pid, _tag} = from
      ref = Process.monitor(pid)
      waiting = Map.update(state.waiting, provider, [{ref, from}], &(&1 ++ [{ref, from}]))
      {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl GenServer
  def handle_call({:release, provider}, _from, state) do
    state = do_release(provider, state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    waiting =
      Map.new(state.waiting, fn {provider, queue} ->
        {provider, Enum.reject(queue, fn {r, _from} -> r == ref end)}
      end)

    {:noreply, %{state | waiting: waiting}}
  end

  @impl GenServer
  def handle_cast({:cancel_acquire, provider, pid}, state) do
    waiting =
      Map.update(state.waiting, provider, [], fn queue ->
        Enum.reject(queue, fn {ref, {from_pid, _tag}} ->
          if from_pid == pid do
            Process.demonitor(ref, [:flush])
            true
          else
            false
          end
        end)
      end)

    {:noreply, %{state | waiting: waiting}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_release(provider, state) do
    case Map.get(state.waiting, provider, []) do
      [] ->
        current = depth(provider)
        :ets.insert(@table, {provider, max(0, current - 1)})
        state

      [{ref, from} | rest] ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, :ok)
        %{state | waiting: Map.put(state.waiting, provider, rest)}
    end
  end
end
