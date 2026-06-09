defmodule ExAthena.Terminal.Server do
  @moduledoc """
  One GenServer per embedded web terminal.

  Owns an interactive shell via `erlexec` (a real pseudo-terminal: prompt,
  colors, job control, Ctrl-C), streams its output to the owning LiveView as
  themed HTML, and dies with its owner (shared-fate cleanup). Output is
  coalesced on a short timer so a flood (`yes`, a big `cat`) becomes a few
  LiveView diffs instead of thousands of messages.

  Started on demand under `ExAthena.Terminal.Supervisor`, named by terminal
  id in `ExAthena.Terminal.Registry` (mirrors `Orchestrator.Coordinator`).

  This is a COMMAND-RUNNER terminal — line-streaming with SGR colors. The
  output renderer (`ExAthena.Terminal.Sgr`) does not emulate cursor control,
  so full-screen TUIs (vim/htop) are out of scope by design.
  """

  use GenServer

  @registry ExAthena.Terminal.Registry
  @supervisor ExAthena.Terminal.Supervisor
  @flush_ms 30
  # Captured raw output replayed to a (re)connecting client so the first
  # prompt / current screen isn't lost to the hook-mount race.
  @scrollback_cap 131_072
  # Ctrl-C byte — the pty translates it to SIGINT for the foreground group.
  @interrupt <<3>>

  # ── Public API ─────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, Map.new(opts), name: via(id))
  end

  @doc "Start (or fetch) a terminal under the DynamicSupervisor."
  def start_for(opts) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Feed raw input (a command line, usually ending in \\n) to the shell."
  def input(id, data), do: cast(id, {:input, data})

  @doc "Send Ctrl-C (SIGINT) to the foreground command."
  def interrupt(id), do: cast(id, :interrupt)

  @doc "Resize the pty (rows × cols)."
  def resize(id, rows, cols), do: cast(id, {:resize, rows, cols})

  @doc "Re-send the captured scrollback to the owner (client (re)connect)."
  def replay(id), do: cast(id, :replay)

  @doc "Kill the shell and stop the server."
  def stop(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  def alive?(id), do: Registry.lookup(@registry, id) != []

  defp cast(id, msg) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> GenServer.cast(pid, msg)
      [] -> :ok
    end
  end

  defp via(id), do: {:via, Registry, {@registry, id}}

  # ── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(%{id: id, owner: owner} = opts) do
    cwd = Map.get(opts, :cwd) || File.cwd!()
    rows = Map.get(opts, :rows, 24)
    cols = Map.get(opts, :cols, 80)

    cmd = Map.get(opts, :shell_cmd) || default_shell_cmd()

    {:ok, pid, os_pid} =
      :exec.run(cmd, [
        :stdin,
        :stdout,
        :stderr,
        :pty,
        :monitor,
        {:cd, to_charlist(cwd)},
        {:winsz, {rows, cols}},
        # A REAL terminal (xterm.js renders the raw VT stream), so run the
        # user's actual interactive shell — aliases, functions, prompt
        # theme (p10k), colors all work natively. Just advertise a capable
        # terminal type.
        {:env, [{~c"TERM", ~c"xterm-256color"}, {~c"COLORTERM", ~c"truecolor"}]}
      ])

    owner_ref = Process.monitor(owner)

    {:ok,
     %{
       id: id,
       owner: owner,
       owner_ref: owner_ref,
       pid: pid,
       os_pid: os_pid,
       buffer: [],
       flush_scheduled?: false,
       scrollback: <<>>
     }}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    :exec.send(state.pid, data)
    {:noreply, state}
  end

  def handle_cast(:interrupt, state) do
    :exec.send(state.pid, @interrupt)
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, state) do
    _ = :exec.winsz(state.os_pid, rows, cols)
    {:noreply, state}
  end

  def handle_cast(:replay, state) do
    if state.scrollback != <<>>,
      do: send(state.owner, {:term_output, state.id, sanitize_replay(state.scrollback)})

    {:noreply, state}
  end

  # erlexec output (pty merges stdout/stderr onto the master fd).
  @impl true
  def handle_info({stream, os_pid, data}, %{os_pid: os_pid} = state)
      when stream in [:stdout, :stderr] do
    {:noreply, buffer(state, data)}
  end

  def handle_info(:flush, state), do: {:noreply, flush(state)}

  # The shell exited.
  def handle_info({:DOWN, _os_pid, :process, pid, reason}, %{pid: pid} = state) do
    state = flush(state)
    send(state.owner, {:term_exit, state.id, exit_code(reason)})
    {:stop, :normal, state}
  end

  # The owning LiveView died — kill the shell and go.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = :exec.stop(state.pid)
    :ok
  end

  # ── Output coalescing ──────────────────────────────────────────────

  defp buffer(state, data) do
    state = %{state | buffer: [state.buffer, data]}

    if state.flush_scheduled? do
      state
    else
      Process.send_after(self(), :flush, @flush_ms)
      %{state | flush_scheduled?: true}
    end
  end

  defp flush(%{buffer: []} = state), do: %{state | flush_scheduled?: false}

  defp flush(state) do
    # Raw VT bytes — xterm.js on the client interprets them.
    data = IO.iodata_to_binary(state.buffer)
    send(state.owner, {:term_output, state.id, data})

    scrollback = cap_scrollback(state.scrollback <> data)
    %{state | buffer: [], flush_scheduled?: false, scrollback: scrollback}
  end

  defp cap_scrollback(sb) when byte_size(sb) <= @scrollback_cap, do: sb

  defp cap_scrollback(sb),
    do: binary_part(sb, byte_size(sb) - @scrollback_cap, @scrollback_cap)

  # Device-query REQUESTS that the shell/prompt (p10k) emitted live. On
  # REPLAY, xterm.js would re-answer them via onData and those answers land
  # at an idle prompt as bogus commands ("command not found: 2RR0",
  # "rgb:0e0e/…"). Strip the queries from replayed bytes — they were already
  # answered during the live session; replay is only for visual restore.
  @query_patterns [
    # DSR (cursor/status report): ESC [ … n
    ~r/\e\[[0-9;?]*n/,
    # Device Attributes request: ESC [ [<=>]? … c  (responses carry a `?`,
    # never present in PTY output, so they're unaffected)
    ~r/\e\[[<=>]?[0-9;]*c/,
    # DECRQM (mode query): ESC [ ? … $ p
    ~r/\e\[\?[0-9;]*\$p/,
    # OSC color/title QUERY: ESC ] … ? … (BEL | ST)
    ~r/\e\][^\a\e]*\?[^\a\e]*(?:\a|\e\\)/
  ]

  @doc false
  # Public for deterministic unit testing (pure transformation).
  def sanitize_replay(bytes) do
    Enum.reduce(@query_patterns, bytes, fn re, acc -> Regex.replace(re, acc, "") end)
  end

  defp exit_code({:exit_status, status}), do: :exec.status(status) |> elem(1)
  defp exit_code(_), do: 0

  # The user's real interactive shell, so aliases/functions/prompt all load.
  defp default_shell_cmd do
    shell = System.get_env("SHELL") || System.find_executable("bash") || "/bin/sh"
    [to_charlist(shell), ~c"-i"]
  end
end
