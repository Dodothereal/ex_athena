defmodule ExAthena.Lsp.Client do
  @moduledoc """
  GenServer wrapping a stdio `Port` that speaks JSON-RPC 2.0 (LSP framing).

  ## Lifecycle

  1. `start_link/1` opens the OS process port and sends the LSP `initialize`
     request via `handle_continue/2`. The GenServer is immediately callable —
     requests received before initialization completes are queued and replayed
     once `initialized` is confirmed.
  2. `request/4` sends a JSON-RPC request and awaits the reply (default 30 s).
     Multiple concurrent callers are safe — replies are correlated by `id`.
  3. `notify/3` sends a one-way notification (no reply expected).
  4. `diagnostics/2` returns cached `textDocument/publishDiagnostics` payloads
     for a given URI (populated by push notifications from the server).
  5. `stop/2` sends the LSP `shutdown` + `exit` sequence, then waits for the
     port to close.

  ## Telemetry

  * `[:ex_athena, :lsp, :spawn]` — discrete event with
    `%{system_time: ...}` measurements and
    `%{language: atom, root: binary, binary: binary, pid: pid, phase: :started | :stopped | :crashed}` metadata.
    Emitted exactly once per phase transition. `:crashed` is emitted only from
    `terminate/2`; the port `:exit_status` handler does not double-emit.
  * `[:ex_athena, :lsp, :request, :start | :stop]` — span around each
    JSON-RPC request/response cycle, metadata
    `%{method: binary, language: atom, root: binary}`.

  ## Assumptions

  LSP servers must not interleave non-JSON-RPC bytes in stdout in normal
  operation. Servers should use `--log-file` flags to avoid mixing stderr
  with the JSON-RPC stream.
  """

  use GenServer

  require Logger

  alias ExAthena.Lsp.Framing
  alias ExAthena.Telemetry

  @default_request_timeout 30_000
  @shutdown_wait_ms 1_000

  # --- public API ---

  @doc """
  Start a client for the given LSP server.

  Options:
    * `:binary` (required) — absolute path to the server executable.
    * `:args` (required) — list of additional CLI args.
    * `:root_uri` (required) — `file:///abs/path` workspace root.
    * `:root` (required) — plain filesystem root path (for telemetry/registry).
    * `:language` (required) — language atom (for telemetry).
    * `:name` (optional) — GenServer name (via-tuple for Registry).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, init_opts} =
      case Keyword.pop(opts, :name) do
        {nil, rest} -> {[], rest}
        {name, rest} -> {[name: name], rest}
      end

    GenServer.start_link(__MODULE__, init_opts, name_opts)
  end

  @doc """
  Send a JSON-RPC request and await the response.

  Returns `{:ok, result}` or `{:error, reason}`. On timeout returns
  `{:error, :timeout}`.
  """
  @spec request(pid(), String.t(), map(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def request(pid, method, params \\ %{}, timeout \\ @default_request_timeout) do
    try do
      GenServer.call(pid, {:request, method, params, timeout}, timeout + 5_000)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc "Send a JSON-RPC notification (no reply)."
  @spec notify(pid(), String.t(), map()) :: :ok
  def notify(pid, method, params \\ %{}) do
    GenServer.cast(pid, {:notify, method, params})
  end

  @doc "Return cached diagnostics for the given `uri`."
  @spec diagnostics(pid(), String.t()) :: [map()]
  def diagnostics(pid, uri) do
    GenServer.call(pid, {:diagnostics, uri})
  end

  @doc "Initiate a graceful LSP shutdown and wait up to `timeout` ms."
  @spec stop(pid(), non_neg_integer()) :: :ok
  def stop(pid, timeout \\ @default_request_timeout) do
    try do
      GenServer.call(pid, :stop, timeout + 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    binary = Keyword.fetch!(opts, :binary)
    args = Keyword.fetch!(opts, :args)
    root_uri = Keyword.fetch!(opts, :root_uri)
    root = Keyword.fetch!(opts, :root)
    language = Keyword.fetch!(opts, :language)

    port = open_port(binary, args, root)

    state = %{
      port: port,
      buffer: "",
      # %{id => {from, method, timer_ref}}
      pending: %{},
      next_id: 1,
      diagnostics: %{},
      capabilities: %{},
      root_uri: root_uri,
      root: root,
      language: language,
      binary: binary,
      # id of the in-flight initialize request; nil after handshake
      init_request_id: nil,
      initialized: false,
      # [{from, method, params, timeout}] collected before handshake
      queued_requests: [],
      shutting_down: false
    }

    Telemetry.event(
      [:ex_athena, :lsp, :spawn],
      %{system_time: System.system_time()},
      %{language: language, root: root, binary: binary, pid: self(), phase: :started}
    )

    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    {id, state} = next_id(state)

    params = %{
      "processId" => System.pid() |> String.to_integer(),
      "rootUri" => state.root_uri,
      "rootPath" => state.root,
      "capabilities" => %{
        "textDocument" => %{
          "publishDiagnostics" => %{"relatedInformation" => true},
          "documentSymbol" => %{"hierarchicalDocumentSymbolSupport" => true}
        },
        "workspace" => %{
          "workspaceFolders" => true,
          "symbol" => %{}
        }
      },
      "clientInfo" => %{"name" => "ex_athena", "version" => "0.5.0"},
      "initializationOptions" => %{}
    }

    send_request(state.port, id, "initialize", params)
    {:noreply, %{state | init_request_id: id}}
  end

  @impl true
  def handle_call({:request, method, params, timeout}, from, state) do
    if state.initialized do
      state = dispatch_request(state, method, params, timeout, from)
      {:noreply, state}
    else
      queued = [{from, method, params, timeout} | state.queued_requests]
      {:noreply, %{state | queued_requests: queued}}
    end
  end

  def handle_call({:diagnostics, uri}, _from, state) do
    {:reply, Map.get(state.diagnostics, uri, []), state}
  end

  def handle_call(:stop, _from, state) do
    if state.shutting_down do
      {:reply, :ok, state}
    else
      state = %{state | shutting_down: true}
      run_shutdown(state)
      {:stop, :normal, :ok, state}
    end
  end

  @impl true
  def handle_cast({:notify, method, params}, state) do
    send_notification(state.port, method, params)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_buffer = state.buffer <> data
    {frames, leftover} = Framing.parse(new_buffer)
    state = %{state | buffer: leftover}
    state = Enum.reduce(frames, state, &dispatch_frame/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # `:crashed` telemetry is emitted from terminate/2 (which fires for every
    # death, including this stop). Don't double-emit here.
    for {_id, {from, _method, timer_ref}} <- state.pending do
      cancel_deadline_timer(timer_ref)
      GenServer.reply(from, {:error, {:lsp_port_exit, status}})
    end

    for {from, _method, _params, _timeout} <- state.queued_requests do
      GenServer.reply(from, {:error, {:lsp_port_exit, status}})
    end

    {:stop, {:lsp_port_exit, status}, state}
  end

  def handle_info({:request_deadline, id}, state) do
    case pop_in(state, [:pending, id]) do
      {nil, state} ->
        {:noreply, state}

      {{from, _method, _timer_ref}, state} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, state}
    end
  end

  def handle_info({:lsp_init_failed, err}, state) do
    {:stop, {:lsp_init_failed, err}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # run_shutdown is a no-op if shutting_down is already true
    # (stop/2 already ran it) or if the port is already dead.
    unless state.shutting_down do
      run_shutdown(state)
    end

    phase = if reason in [:normal, :shutdown], do: :stopped, else: :crashed

    Telemetry.event(
      [:ex_athena, :lsp, :spawn],
      %{system_time: System.system_time()},
      %{
        language: state.language,
        root: state.root,
        binary: state.binary,
        pid: self(),
        phase: phase
      }
    )

    :ok
  end

  # --- frame dispatch ---

  defp dispatch_frame(body, state) do
    case Jason.decode(body) do
      {:ok, msg} ->
        handle_message(msg, state)

      {:error, _} ->
        Logger.warning("[ExAthena.Lsp.Client] invalid JSON frame dropped: #{inspect(body)}")
        state
    end
  end

  # Initialize response — completes the handshake.
  defp handle_message(%{"id" => id, "result" => result}, %{init_request_id: id} = state)
       when not is_nil(id) do
    caps = (result || %{}) |> Map.get("capabilities", %{})
    state = %{state | capabilities: caps, init_request_id: nil, initialized: true}
    send_notification(state.port, "initialized", %{})
    flush_queued_requests(state)
  end

  # Initialize error response — fail every queued caller and stop the GenServer.
  # Without this clause, an `initialize` error would fall through to the catch-all
  # and queued requests would hang until their caller-side timeout.
  defp handle_message(%{"id" => id, "error" => err}, %{init_request_id: id} = state)
       when not is_nil(id) do
    Logger.error("[ExAthena.Lsp.Client] LSP initialize failed: #{inspect(err)}")

    for {from, _method, _params, _timeout} <- state.queued_requests do
      GenServer.reply(from, {:error, {:lsp_init_failed, err}})
    end

    send(self(), {:lsp_init_failed, err})
    %{state | queued_requests: [], init_request_id: nil}
  end

  # Response to one of our requests.
  defp handle_message(%{"id" => id} = msg, state) when is_map_key(state.pending, id) do
    {{from, method, timer_ref}, state} = pop_in(state, [:pending, id])
    cancel_deadline_timer(timer_ref)

    Telemetry.event(
      [:ex_athena, :lsp, :request, :stop],
      %{system_time: System.system_time()},
      %{method: method, language: state.language, root: state.root}
    )

    reply =
      cond do
        Map.has_key?(msg, "result") -> {:ok, msg["result"]}
        Map.has_key?(msg, "error") -> {:error, msg["error"]}
        true -> {:error, :malformed_response}
      end

    GenServer.reply(from, reply)
    state
  end

  # Server-initiated request — reply with MethodNotFound.
  defp handle_message(%{"method" => _method, "id" => id}, state) do
    error =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "MethodNotFound"}
      })

    send_raw(state.port, error)
    state
  end

  # Notification.
  defp handle_message(%{"method" => method} = msg, state) do
    handle_notification(method, Map.get(msg, "params", %{}), state)
  end

  defp handle_message(_msg, state), do: state

  defp handle_notification("textDocument/publishDiagnostics", params, state) do
    uri = Map.get(params, "uri", "")
    diags = Map.get(params, "diagnostics", [])
    %{state | diagnostics: Map.put(state.diagnostics, uri, diags)}
  end

  defp handle_notification("window/logMessage", params, state) do
    Logger.debug("[LSP:#{state.language}] #{Map.get(params, "message", "")}")
    state
  end

  defp handle_notification(_method, _params, state), do: state

  # --- request helpers ---

  defp dispatch_request(state, method, params, timeout, from) do
    {id, state} = next_id(state)

    Telemetry.event(
      [:ex_athena, :lsp, :request, :start],
      %{system_time: System.system_time()},
      %{method: method, language: state.language, root: state.root}
    )

    timer_ref = Process.send_after(self(), {:request_deadline, id}, timeout)
    state = put_in(state, [:pending, id], {from, method, timer_ref})
    send_request(state.port, id, method, params)
    state
  end

  defp cancel_deadline_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_deadline_timer(_), do: :ok

  defp flush_queued_requests(state) do
    queued = Enum.reverse(state.queued_requests)
    state = %{state | queued_requests: []}

    Enum.reduce(queued, state, fn {from, method, params, timeout}, acc ->
      dispatch_request(acc, method, params, timeout, from)
    end)
  end

  # --- port helpers ---

  defp open_port(binary, args, root) do
    Port.open({:spawn_executable, binary}, [
      :binary,
      :exit_status,
      args: args,
      cd: root
    ])
  end

  defp send_request(port, id, method, params) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    send_raw(port, msg)
  end

  defp send_notification(port, method, params) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
      })

    send_raw(port, msg)
  end

  defp send_raw(port, json) do
    frame = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"

    try do
      Port.command(port, frame)
    rescue
      ArgumentError -> :error
    end
  end

  defp next_id(%{next_id: id} = state), do: {id, %{state | next_id: id + 1}}

  defp run_shutdown(state) do
    {id, _state} = next_id(state)
    send_request(state.port, id, "shutdown", %{})

    receive do
      {port, {:data, _}} when port == state.port -> :ok
      {port, {:exit_status, _}} when port == state.port -> :ok
    after
      @shutdown_wait_ms -> :ok
    end

    send_notification(state.port, "exit", %{})

    receive do
      {port, {:exit_status, _}} when port == state.port -> :ok
    after
      @shutdown_wait_ms ->
        try do
          Port.close(state.port)
        rescue
          ArgumentError -> :ok
        end
    end
  end
end
