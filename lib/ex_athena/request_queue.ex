defmodule ExAthena.RequestQueue do
  @moduledoc """
  ETS-backed GenServer semaphore that limits concurrent in-flight requests per provider.

  Each provider has an independent slot cap (see `ExAthena.Config.request_queue_max_depth/1`).
  `with_slot/3` is the primary entry point: it acquires a slot, runs the fun, and
  releases on every exit path. `acquire/2` blocks the caller until a slot is
  available; `release/1` frees the slot and wakes the next queued caller (FIFO).
  `depth/1` reads the ETS counter directly, never blocking the caller.

  Local inference servers (ollama / llama.cpp / exo) can only serve 1–3 requests
  concurrently; the gate keeps concurrent agent loops from overwhelming them and
  gives hosts queue visibility (`waiting_count/1`, `:on_wait` callbacks).

  The queue is enabled by default. Disable via:

      config :ex_athena, :request_queue, enabled: false

  When the GenServer is not running (feature disabled), `acquire/1` and
  `release/1` are no-ops returning `:ok` and `with_slot/3` just runs the fun.

  ## Crash safety

  Both sides of the semaphore are monitored:

    * **Waiters** — if a blocked caller exits before its slot is granted, the
      monitor fires and removes the dead entry from the queue.
    * **Holders** — if a caller that holds a slot dies without releasing (e.g.
      brutally killed mid-stream), the monitor fires and the slot is reclaimed,
      granting the next waiter. This covers exits that skip `after` blocks.

  ## Waiter ordering

  FIFO. Each waiter entry carries a reserved `priority` field (currently always
  `0`) so priority scheduling can be added later without reshaping the queue.
  """

  use GenServer

  alias ExAthena.{Config, Telemetry}

  @table __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a slot, run `fun`, release the slot on every exit path.

  This is the canonical way to gate a provider call. Telemetry
  (`[:ex_athena, :request_queue, :wait | :acquired | :released | :timeout]`)
  is emitted around the slot lifecycle.

  Passes straight through (no acquire) when:

    * `provider` is `nil` or a module (custom provider modules are not gated),
    * the `queue: false` option is given,
    * the queue feature is disabled in config.

  ## Options

    * `:queue` — `false` bypasses the gate for this call (default `true`).
    * `:timeout` — milliseconds (or `:infinity`) to wait for a slot before
      returning `{:error, :request_queue_timeout}` (default `5_000`).
    * `:on_wait` — optional `fun/1` invoked with `:waiting` just before a
      blocking acquire and `{:acquired, waited_ms}` once the slot is granted.
      Not invoked at all when a slot is free — hosts use this to show a
      "waiting on GPU" state only when there is actually a wait.
  """
  @spec with_slot(atom() | module() | nil, (-> result), keyword()) ::
          result | {:error, :request_queue_timeout}
        when result: term()
  def with_slot(provider, fun, opts \\ [])

  def with_slot(provider, fun, opts) when is_atom(provider) and not is_nil(provider) do
    cond do
      module_atom?(provider) -> fun.()
      Keyword.get(opts, :queue, true) == false -> fun.()
      not Config.request_queue_enabled?() -> fun.()
      true -> do_with_slot(provider, fun, opts)
    end
  end

  def with_slot(_provider, fun, _opts), do: fun.()

  @doc """
  Acquire a slot for `provider`. Blocks the caller until a slot is available or
  `timeout` milliseconds elapse (default 5 000 ms; `:infinity` supported).

  The calling process is monitored while it holds the slot — if it dies without
  releasing, the slot is reclaimed automatically.

  Returns `:ok` when a slot is granted. When the GenServer is not running
  (feature disabled), returns `:ok` immediately as a no-op.
  """
  @spec acquire(atom(), timeout()) :: :ok
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
  Return the number of callers currently queued (blocked) for `provider`.

  Hosts poll this to render queue-pressure indicators. Returns `0` when the
  queue is disabled.
  """
  @spec waiting_count(atom()) :: non_neg_integer()
  def waiting_count(provider) do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _pid -> GenServer.call(__MODULE__, {:waiting_count, provider})
    end
  end

  @doc """
  Cancel any pending acquire for the calling process on `provider`.

  Called automatically by `with_slot/3` when an acquire timeout fires so that
  stale waiting entries do not prevent depth from decrementing on the next
  `release/1`.
  """
  @spec cancel_acquire(atom()) :: :ok
  def cancel_acquire(provider) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:cancel_acquire, provider, self()})
    end
  end

  # ---------------------------------------------------------------------------
  # with_slot internals
  # ---------------------------------------------------------------------------

  defp do_with_slot(provider, fun, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    on_wait = Keyword.get(opts, :on_wait)

    start_ms = System.monotonic_time(:millisecond)
    Telemetry.event([:ex_athena, :request_queue, :wait], %{}, %{provider: provider})

    # Cheap ETS pre-check so hosts only see :waiting when the acquire will
    # actually block. Racy by design — a false positive/negative here only
    # affects the UI hint, never correctness.
    blocked? = depth(provider) >= Config.request_queue_max_depth(provider)
    if blocked? and is_function(on_wait, 1), do: on_wait.(:waiting)

    case do_acquire(provider, timeout) do
      :ok ->
        wait_ms = System.monotonic_time(:millisecond) - start_ms
        if blocked? and is_function(on_wait, 1), do: on_wait.({:acquired, wait_ms})

        Telemetry.event(
          [:ex_athena, :request_queue, :acquired],
          %{wait_ms: wait_ms, depth: depth(provider)},
          %{provider: provider}
        )

        try do
          fun.()
        after
          release(provider)

          Telemetry.event(
            [:ex_athena, :request_queue, :released],
            %{depth: depth(provider)},
            %{provider: provider}
          )
        end

      {:error, :timeout} ->
        waited_ms = System.monotonic_time(:millisecond) - start_ms

        Telemetry.event(
          [:ex_athena, :request_queue, :timeout],
          %{waited_ms: waited_ms},
          %{provider: provider}
        )

        {:error, :request_queue_timeout}
    end
  end

  defp do_acquire(provider, timeout) do
    try do
      acquire(provider, timeout)
    catch
      :exit, _ ->
        cancel_acquire(provider)
        {:error, :timeout}
    end
  end

  # Module atoms (Elixir.*) are custom provider modules — never gated.
  defp module_atom?(atom) do
    atom |> Atom.to_string() |> String.starts_with?("Elixir.")
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{waiting: %{}, holders: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, provider}, {pid, _tag} = from, state) do
    max = Config.request_queue_max_depth(provider)
    current = depth(provider)

    if current < max do
      :ets.insert(@table, {provider, current + 1})
      {:reply, :ok, register_holder(state, pid, provider)}
    else
      ref = Process.monitor(pid)
      # priority is reserved for future scheduling; FIFO for now.
      waiter = %{ref: ref, from: from, priority: 0}
      waiting = Map.update(state.waiting, provider, [waiter], &(&1 ++ [waiter]))
      {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl GenServer
  def handle_call({:release, provider}, {pid, _tag}, state) do
    state = state |> deregister_holder(pid, provider) |> do_release(provider)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:waiting_count, provider}, _from, state) do
    {:reply, length(Map.get(state.waiting, provider, [])), state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.holders, ref) do
      {{_pid, provider}, holders} ->
        # A slot holder died without releasing — reclaim its slot.
        {:noreply, do_release(%{state | holders: holders}, provider)}

      {nil, _holders} ->
        # A blocked waiter died — drop its queue entry.
        waiting =
          Map.new(state.waiting, fn {provider, queue} ->
            {provider, Enum.reject(queue, &(&1.ref == ref))}
          end)

        {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl GenServer
  def handle_cast({:cancel_acquire, provider, pid}, state) do
    waiting =
      Map.update(state.waiting, provider, [], fn queue ->
        Enum.reject(queue, fn %{ref: ref, from: {from_pid, _tag}} ->
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

  # Grant the freed slot to the next waiter (FIFO) or decrement the depth.
  # A granted waiter keeps its monitor and becomes a holder — the same ref
  # now guards against the holder dying mid-request.
  defp do_release(state, provider) do
    case Map.get(state.waiting, provider, []) do
      [] ->
        current = depth(provider)
        :ets.insert(@table, {provider, max(0, current - 1)})
        state

      [%{ref: ref, from: {pid, _tag} = from} | rest] ->
        GenServer.reply(from, :ok)

        %{
          state
          | waiting: Map.put(state.waiting, provider, rest),
            holders: Map.put(state.holders, ref, {pid, provider})
        }
    end
  end

  defp register_holder(state, pid, provider) do
    ref = Process.monitor(pid)
    %{state | holders: Map.put(state.holders, ref, {pid, provider})}
  end

  # Remove ONE holder entry matching this pid+provider (a process may hold
  # several slots). A release with no matching holder (legacy callers or
  # cross-process releases) falls through — do_release still decrements.
  defp deregister_holder(state, pid, provider) do
    case Enum.find(state.holders, fn {_ref, hp} -> hp == {pid, provider} end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        %{state | holders: Map.delete(state.holders, ref)}

      nil ->
        state
    end
  end
end
