defmodule ExAthena.Web.Live.ChatLive do
  use Phoenix.LiveView

  alias ExAthena.Chat.{LlamaCpp, Ollama}
  alias ExAthena.Messages
  alias ExAthena.Web.Sessions

  @providers [
    {"llama.cpp", "llamacpp"},
    {"Ollama", "ollama"},
    {"Claude / Anthropic", "claude"},
    {"OpenAI-compatible", "openai_compatible"},
    {"Gemini", "gemini"}
  ]
  @modes [
    {"ReAct", "react"},
    {"Plan & Solve", "plan_and_solve"},
    {"Reflexion", "reflexion"}
  ]

  # How many diff lines to show before truncating
  @max_diff_lines 300

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    provider = default_provider()
    model = default_model(provider)
    session_id = unique_id()

    socket =
      assign(socket,
        # Session
        session_id: session_id,
        session_title: nil,
        session_created_at: DateTime.utc_now(),
        sessions: [],
        show_sessions: false,
        # Model settings
        provider: provider,
        model: model,
        mode: "react",
        available_models: [],
        providers: @providers,
        modes: @modes,
        # Conversation
        messages: [],
        streaming: false,
        stream_text: "",
        stream_events: [],
        stream_tool_ui: %{},
        current_action: nil,
        ex_messages: [],
        # Stored tool UI payloads (diff/process/file) keyed by tool_call_id
        tool_uis: %{},
        expanded_uis: MapSet.new(),
        # Status / errors
        status: nil,
        error: nil
      )

    if connected?(socket) do
      send(self(), {:load_models, provider})
      send(self(), :load_sessions)
    end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # User events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" -> {:noreply, socket}
      socket.assigns.streaming -> {:noreply, socket}
      true -> start_agent_run(socket, text)
    end
  end

  def handle_event("clear", _params, socket) do
    session_id = unique_id()

    {:noreply,
     assign(socket,
       session_id: session_id,
       session_title: nil,
       session_created_at: DateTime.utc_now(),
       messages: [],
       ex_messages: [],
       tool_uis: %{},
       expanded_uis: MapSet.new(),
       status: nil,
       error: nil,
       stream_text: "",
       stream_events: [],
       stream_tool_ui: %{},
       current_action: nil
     )}
  end

  def handle_event("set_provider", %{"value" => provider}, socket) do
    model = default_model(provider)
    send(self(), {:load_models, provider})
    {:noreply, assign(socket, provider: provider, model: model, available_models: [])}
  end

  def handle_event("set_model", %{"value" => model}, socket) do
    {:noreply, assign(socket, model: model)}
  end

  def handle_event("set_mode", %{"value" => mode}, socket) do
    {:noreply, assign(socket, mode: mode)}
  end

  def handle_event("toggle_sessions", _params, socket) do
    show = !socket.assigns.show_sessions
    socket = if show, do: assign(socket, sessions: Sessions.list()), else: socket
    {:noreply, assign(socket, show_sessions: show)}
  end

  def handle_event("new_session", _params, socket) do
    handle_event("clear", %{}, socket)
  end

  def handle_event("load_session", %{"id" => id}, socket) do
    case Sessions.load(id) do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           session_id: data.id,
           session_title: data.title,
           session_created_at: Map.get(data, :created_at, DateTime.utc_now()),
           provider: data.provider,
           model: data.model,
           mode: data.mode,
           messages: data.display_messages,
           ex_messages: data.ex_messages,
           tool_uis: Map.get(data, :tool_uis, %{}),
           expanded_uis: MapSet.new(),
           status: nil,
           error: nil,
           show_sessions: false
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load session: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    Sessions.delete(id)
    {:noreply, assign(socket, sessions: Sessions.list())}
  end

  def handle_event("fork_at", %{"msg_id" => msg_id}, socket) do
    idx = Enum.find_index(socket.assigns.messages, &(&1.id == msg_id))

    case idx do
      nil ->
        {:noreply, socket}

      n ->
        forked_messages = Enum.take(socket.assigns.messages, n + 1)
        # Use the ex_snapshot stored on the target assistant message
        ex_messages =
          forked_messages
          |> Enum.reverse()
          |> Enum.find_value(fn msg -> Map.get(msg, :ex_snapshot) end)
          |> case do
            nil -> socket.assigns.ex_messages
            snap -> snap
          end

        new_id = unique_id()
        title = derive_title(forked_messages)

        {:noreply,
         assign(socket,
           session_id: new_id,
           session_title: title,
           session_created_at: DateTime.utc_now(),
           messages: forked_messages,
           ex_messages: ex_messages,
           status: nil,
           error: nil,
           stream_text: "",
           stream_events: [],
           stream_tool_ui: %{},
           current_action: nil,
           show_sessions: false
         )}
    end
  end

  def handle_event("toggle_ui", %{"id" => tool_call_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_uis, tool_call_id) do
        MapSet.delete(socket.assigns.expanded_uis, tool_call_id)
      else
        MapSet.put(socket.assigns.expanded_uis, tool_call_id)
      end

    {:noreply, assign(socket, expanded_uis: expanded)}
  end

  # ---------------------------------------------------------------------------
  # Internal messages
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_sessions, socket) do
    {:noreply, assign(socket, sessions: Sessions.list())}
  end

  def handle_info({:load_models, provider}, socket) do
    {:noreply, assign(socket, available_models: fetch_models(provider))}
  end

  def handle_info({:athena, {:content, text}}, socket) do
    {:noreply, update(socket, :stream_text, &(&1 <> text))}
  end

  def handle_info({:athena, {:tool_call, tc}}, socket) do
    event = %{type: :call, id: tc.id, name: tc.name, arguments: tc.arguments}
    action = action_label(tc.name, tc.arguments)

    {:noreply,
     socket
     |> update(:stream_events, &(&1 ++ [event]))
     |> assign(current_action: action)}
  end

  def handle_info({:athena, {:tool_result, tr}}, socket) do
    event = %{
      type: :result,
      tool_call_id: tr.tool_call_id,
      content: to_string(tr.content),
      is_error: tr.is_error || false
    }

    {:noreply,
     socket
     |> update(:stream_events, &(&1 ++ [event]))
     |> assign(current_action: nil)}
  end

  def handle_info({:athena, {:tool_ui, %{tool_call_id: id, kind: kind, payload: payload}}}, socket) do
    ui_entry = build_ui_entry(kind, payload)
    {:noreply, update(socket, :stream_tool_ui, &Map.put(&1, id, ui_entry))}
  end

  def handle_info({:athena, {:error, reason}}, socket) do
    {:noreply, assign(socket, error: inspect(reason))}
  end

  def handle_info({:athena, _other}, socket), do: {:noreply, socket}

  def handle_info({:athena_done, result}, socket) do
    usage = result.usage || %{}

    status = %{
      iterations: result.iterations || 0,
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      cost_usd: result.cost_usd || 0.0
    }

    ex_messages =
      case result.messages do
        [_ | _] = msgs -> msgs
        _ -> socket.assigns.ex_messages
      end

    new_tool_uis = Map.merge(socket.assigns.tool_uis, socket.assigns.stream_tool_ui)

    assistant_msg = %{
      id: unique_id(),
      role: :assistant,
      text: socket.assigns.stream_text,
      tool_events: socket.assigns.stream_events,
      status: status,
      ex_snapshot: ex_messages
    }

    messages = socket.assigns.messages ++ [assistant_msg]
    title = socket.assigns.session_title || derive_title(messages)

    socket =
      assign(socket,
        messages: messages,
        ex_messages: ex_messages,
        tool_uis: new_tool_uis,
        streaming: false,
        stream_text: "",
        stream_events: [],
        stream_tool_ui: %{},
        current_action: nil,
        status: status,
        error: nil,
        session_title: title
      )

    save_session(socket)
    {:noreply, socket}
  end

  def handle_info({:athena_error, reason}, socket) do
    {:noreply, assign(socket, streaming: false, current_action: nil, error: inspect(reason))}
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, max_diff_lines: @max_diff_lines)

    ~H"""
    <div class="app">
      <%!-- Sidebar --%>
      <aside class="sidebar">
        <div class="sidebar-logo">
          <span class="logo-text">ExAthena</span>
          <span class="logo-sub">agent loop</span>
        </div>

        <div class="sidebar-section">
          <label class="field-label">Provider</label>
          <select class="field-select" phx-change="set_provider" name="value">
            <option :for={{label, val} <- @providers} value={val} selected={@provider == val}>
              {label}
            </option>
          </select>
        </div>

        <div class="sidebar-section">
          <label class="field-label">Model</label>
          <%= if @available_models != [] do %>
            <select class="field-select" phx-change="set_model" name="value">
              <option :for={m <- @available_models} value={m} selected={@model == m}>{m}</option>
            </select>
          <% else %>
            <input
              class="field-input"
              type="text"
              value={@model}
              placeholder="model name"
              phx-blur="set_model"
              name="value"
            />
          <% end %>
        </div>

        <div class="sidebar-section">
          <label class="field-label">Mode</label>
          <select class="field-select" phx-change="set_mode" name="value">
            <option :for={{label, val} <- @modes} value={val} selected={@mode == val}>
              {label}
            </option>
          </select>
        </div>

        <div class="sidebar-section sidebar-actions">
          <button class="btn-secondary" phx-click="new_session">+ New session</button>
          <button class="btn-secondary" phx-click="toggle_sessions">
            {if @show_sessions, do: "▲ Sessions", else: "▼ Sessions"}
          </button>
        </div>

        <%!-- Session list --%>
        <%= if @show_sessions do %>
          <div class="session-list">
            <%= if @sessions == [] do %>
              <div class="session-empty">No saved sessions</div>
            <% else %>
              <div
                :for={s <- @sessions}
                class={"session-item#{if s.id == @session_id, do: " session-item--active", else: ""}"}
              >
                <button class="session-load" phx-click="load_session" phx-value-id={s.id}>
                  <span class="session-title">{s.title || "Untitled"}</span>
                  <span class="session-meta">{s.provider} · {format_dt(s.updated_at)}</span>
                </button>
                <button class="session-delete" phx-click="delete_session" phx-value-id={s.id} title="Delete">×</button>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if @status do %>
          <div class="status-block">
            <div class="status-row">
              <span class="status-key">iter</span>
              <span class="status-val">{@status.iterations}</span>
            </div>
            <div class="status-row">
              <span class="status-key">in</span>
              <span class="status-val">{@status.input_tokens} tok</span>
            </div>
            <div class="status-row">
              <span class="status-key">out</span>
              <span class="status-val">{@status.output_tokens} tok</span>
            </div>
            <div class="status-row">
              <span class="status-key">cost</span>
              <span class="status-val">${format_cost(@status.cost_usd)}</span>
            </div>
          </div>
        <% end %>
      </aside>

      <%!-- Main chat --%>
      <main class="chat-main">
        <div class="messages" id="messages" phx-hook="ScrollToBottom">
          <%= if @messages == [] and not @streaming do %>
            <div class="empty-state">
              <div class="empty-icon">◈</div>
              <div class="empty-title">ExAthena</div>
              <div class="empty-sub">{@provider} · {@mode}</div>
            </div>
          <% end %>

          <.message
            :for={msg <- @messages}
            msg={msg}
            tool_uis={@tool_uis}
            expanded_uis={@expanded_uis}
            max_diff_lines={@max_diff_lines}
          />

          <%= if @streaming do %>
            <.streaming_message
              text={@stream_text}
              events={@stream_events}
              current_action={@current_action}
              tool_uis={@stream_tool_ui}
              expanded_uis={@expanded_uis}
            />
          <% end %>

          <%= if @error do %>
            <div class="msg-error">⚠ {@error}</div>
          <% end %>
        </div>

        <div class="input-bar">
          <form class="input-form" phx-submit="send">
            <textarea
              id="chat-input"
              class="input-textarea"
              name="text"
              placeholder="Message ExAthena… (Enter to send, Shift+Enter for newline)"
              disabled={@streaming}
              phx-hook="SubmitOnEnter"
            ></textarea>
            <button
              class={"btn-send#{if @streaming, do: " btn-send--disabled", else: ""}"}
              type="submit"
              disabled={@streaming}
            >
              <%= if @streaming do %>
                <span class="spinner"></span>
              <% else %>
                ↑
              <% end %>
            </button>
          </form>
        </div>
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  defp message(%{msg: %{role: :user}} = assigns) do
    ~H"""
    <div class="msg msg--user">
      <div class="msg-role">you</div>
      <div class="msg-body">{@msg.text}</div>
    </div>
    """
  end

  defp message(%{msg: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="msg msg--assistant">
      <div class="msg-role">
        assistant
        <button class="btn-fork" phx-click="fork_at" phx-value-msg_id={@msg.id} title="Fork conversation from here">
          ⑂ fork
        </button>
      </div>
      <.tool_events
        events={@msg.tool_events}
        tool_uis={@tool_uis}
        expanded_uis={@expanded_uis}
      />
      <div
        class="msg-body md"
        id={"md-#{@msg.id}"}
        phx-hook="MarkdownRender"
        data-raw={@msg.text}
      ></div>
      <%= if @msg.status do %>
        <div class="msg-footer">
          iter={@msg.status.iterations} · {@msg.status.input_tokens}/{@msg.status.output_tokens} tok · ${format_cost(@msg.status.cost_usd)}
        </div>
      <% end %>
    </div>
    """
  end

  defp streaming_message(assigns) do
    ~H"""
    <div class="msg msg--assistant msg--streaming">
      <div class="msg-role">
        assistant
        <span class="thinking-dot">●</span>
        <%= if @current_action do %>
          <span class="current-action">
            <span class="action-icon">⚡</span> {@current_action}
          </span>
        <% end %>
      </div>
      <.tool_events events={@events} tool_uis={@tool_uis} expanded_uis={@expanded_uis} />
      <div class="msg-body" style="white-space: pre-wrap">
        {if @text == "", do: "", else: @text}<span class="cursor">▋</span>
      </div>
    </div>
    """
  end

  defp tool_events(%{events: []} = assigns), do: ~H""

  defp tool_events(assigns) do
    calls = Enum.filter(assigns.events, &(&1.type == :call))
    results_by_id = assigns.events |> Enum.filter(&(&1.type == :result)) |> Map.new(&{&1.tool_call_id, &1})
    assigns = assign(assigns, calls: calls, results_by_id: results_by_id)

    ~H"""
    <div class="tool-events">
      <div :for={call <- @calls} class="tool-call">
        <div class="tool-call-header">
          <span class="tool-arrow">→</span>
          <span class="tool-name">{call.name}</span>
          <span class="tool-args">{preview_args(call.arguments)}</span>
        </div>

        <%= if result = Map.get(@results_by_id, call.id) do %>
          <div class={"tool-result#{if result.is_error, do: " tool-result--error", else: ""}"}>
            <span class="tool-arrow">{if result.is_error, do: "✗", else: "←"}</span>
            <span class="tool-result-content">{summarize(result.content)}</span>
            <%= if Map.has_key?(@tool_uis, call.id) do %>
              <button class="btn-view-ui" phx-click="toggle_ui" phx-value-id={call.id}>
                {if MapSet.member?(@expanded_uis, call.id), do: "▲ hide", else: "▼ view"}
              </button>
            <% end %>
          </div>
          <%= if MapSet.member?(@expanded_uis, call.id) and Map.has_key?(@tool_uis, call.id) do %>
            <.tool_ui_panel ui={Map.get(@tool_uis, call.id)} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp tool_ui_panel(%{ui: %{kind: :diff}} = assigns) do
    ~H"""
    <div class="ui-panel ui-panel--diff">
      <div class="diff-header">
        <span class="diff-path">{@ui.path}</span>
        <span class="diff-stats">{@ui.changed_lines} changed / {@ui.total_lines} lines</span>
      </div>
      <div class="diff-body">
        <div :for={{kind, line} <- @ui.lines} class={"diff-line diff-#{kind}"}>
          <span class="diff-mark">{diff_mark(kind)}</span>
          <span class="diff-text">{line}</span>
        </div>
        <%= if @ui.truncated do %>
          <div class="diff-truncated">… showing first {@ui.shown} lines</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp tool_ui_panel(%{ui: %{kind: :process}} = assigns) do
    ~H"""
    <div class="ui-panel ui-panel--process">
      <div class="process-header">
        <span class="process-cmd">{@ui.command}</span>
        <span class={"process-exit#{if @ui.exit_code != 0, do: " process-exit--error", else: ""}"}> exit {@ui.exit_code}</span>
        <span class="process-time">{@ui.duration_ms}ms</span>
      </div>
      <pre class="process-output">{@ui.stdout}</pre>
    </div>
    """
  end

  defp tool_ui_panel(%{ui: %{kind: :file}} = assigns) do
    ~H"""
    <div class="ui-panel ui-panel--file">
      <div class="file-header">{@ui.path}</div>
      <pre class="file-content">{@ui.content}</pre>
    </div>
    """
  end

  defp tool_ui_panel(assigns), do: ~H""

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_agent_run(socket, text) do
    pid = self()
    provider = socket.assigns.provider
    model = socket.assigns.model
    mode = socket.assigns.mode

    user_msg = %{id: unique_id(), role: :user, text: text, tool_events: [], status: nil}
    new_ex_msg = Messages.user(text)
    ex_messages = socket.assigns.ex_messages ++ [new_ex_msg]

    Task.start(fn ->
      on_event = fn event -> send(pid, {:athena, event}) end

      opts =
        [
          provider: safe_atom(provider, :llamacpp),
          mode: safe_mode(mode),
          messages: ex_messages,
          tools: :all,
          permission_mode: :accept_edits,
          on_event: on_event,
          timeout_ms: 24 * 60 * 60 * 1000
        ]
        |> maybe_put_model(model)
        |> apply_base_url(provider)

      case ExAthena.run(nil, opts) do
        {:ok, result} -> send(pid, {:athena_done, result})
        {:error, reason} -> send(pid, {:athena_error, reason})
      end
    end)

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [user_msg],
       ex_messages: ex_messages,
       streaming: true,
       stream_text: "",
       stream_events: [],
       stream_tool_ui: %{},
       current_action: nil,
       error: nil
     )}
  end

  defp save_session(socket) do
    a = socket.assigns

    Sessions.save(%{
      id: a.session_id,
      title: a.session_title,
      provider: a.provider,
      model: a.model,
      mode: a.mode,
      created_at: a.session_created_at,
      updated_at: DateTime.utc_now(),
      display_messages: a.messages,
      ex_messages: a.ex_messages,
      tool_uis: a.tool_uis
    })
  end

  defp build_ui_entry(:diff, %{path: path, before: before, after: after_text} = _payload) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_text, "\n")

    all_lines =
      List.myers_difference(before_lines, after_lines)
      |> Enum.flat_map(fn
        {:eq, lines} -> Enum.map(lines, &{:eq, &1})
        {:ins, lines} -> Enum.map(lines, &{:ins, &1})
        {:del, lines} -> Enum.map(lines, &{:del, &1})
      end)

    visible = Enum.take(all_lines, @max_diff_lines)
    total = length(all_lines)
    changed = Enum.count(all_lines, fn {k, _} -> k != :eq end)

    %{
      kind: :diff,
      path: Path.relative_to_cwd(path),
      lines: visible,
      total_lines: total,
      changed_lines: changed,
      shown: length(visible),
      truncated: total > @max_diff_lines
    }
  end

  defp build_ui_entry(:process, %{command: cmd, exit_code: code, stdout: out, duration_ms: ms}) do
    %{
      kind: :process,
      command: cmd,
      exit_code: code,
      stdout: truncate(out, 10_000),
      duration_ms: ms
    }
  end

  defp build_ui_entry(:file, %{path: path, content: content}) do
    %{kind: :file, path: path, content: truncate(content, 8_000)}
  end

  defp build_ui_entry(_kind, _payload), do: nil

  defp diff_mark(:ins), do: "+"
  defp diff_mark(:del), do: "−"
  defp diff_mark(:eq), do: " "

  defp action_label("read", args) do
    path = Map.get(args, "path", "")
    "Reading · #{Path.basename(path)}"
  end

  defp action_label("bash", args) do
    cmd = args |> Map.get("command", "") |> String.slice(0, 60)
    "Shell · #{cmd}"
  end

  defp action_label("grep", args) do
    pattern = Map.get(args, "pattern", "")
    "Grep · #{pattern}"
  end

  defp action_label("glob", args) do
    pattern = Map.get(args, "pattern", "")
    "Glob · #{pattern}"
  end

  defp action_label("write", args) do
    path = Map.get(args, "path", "")
    "Writing · #{Path.basename(path)}"
  end

  defp action_label("edit", args) do
    path = Map.get(args, "path", "")
    "Editing · #{Path.basename(path)}"
  end

  defp action_label("apply_patch", args) do
    path = Map.get(args, "path", "")
    "Patching · #{Path.basename(path)}"
  end

  defp action_label("web_fetch", args) do
    url = Map.get(args, "url", "")
    "Fetching · #{truncate(url, 50)}"
  end

  defp action_label("todo_write", _), do: "Updating todos"

  defp action_label(name, _), do: name

  defp derive_title([]), do: "Untitled"

  defp derive_title(messages) do
    messages
    |> Enum.find(&(&1.role == :user))
    |> case do
      nil -> "Untitled"
      msg -> truncate(msg.text, 60)
    end
  end

  defp fetch_models("llamacpp") do
    base_url = Application.get_env(:ex_athena, :llamacpp, [])[:base_url]
    opts = if base_url, do: [base_url: base_url], else: []
    case LlamaCpp.list_models(opts) do
      {:ok, models} -> models
      _ -> []
    end
  end

  defp fetch_models("ollama") do
    base_url = Application.get_env(:ex_athena, :ollama, [])[:base_url]
    opts = if base_url, do: [base_url: base_url], else: []
    case Ollama.list_models(opts) do
      {:ok, models} -> models
      _ -> []
    end
  end

  defp fetch_models(_), do: []

  defp default_provider do
    Application.get_env(:ex_athena, :default_provider, :llamacpp) |> to_string()
  end

  defp default_model(provider) do
    atom = safe_atom(provider, :llamacpp)
    Application.get_env(:ex_athena, atom, [])[:model] || "llama3.1"
  end

  defp apply_base_url(opts, "llamacpp") do
    configured = Application.get_env(:ex_athena, :llamacpp, [])[:base_url]
    Keyword.put_new(opts, :base_url, configured || "http://localhost:8080")
  end

  defp apply_base_url(opts, "ollama") do
    configured = Application.get_env(:ex_athena, :ollama, [])[:base_url]
    Keyword.put_new(opts, :base_url, configured || "http://localhost:11434")
  end

  defp apply_base_url(opts, _), do: opts

  defp maybe_put_model(opts, m) when is_binary(m) and m != "", do: Keyword.put(opts, :model, m)
  defp maybe_put_model(opts, _), do: opts

  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    _ -> default
  end

  defp safe_mode(m) when m in ["react", "plan_and_solve", "reflexion"],
    do: String.to_existing_atom(m)

  defp safe_mode(_), do: :react

  defp unique_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  defp format_cost(nil), do: "0.0000"
  defp format_cost(n), do: :erlang.float_to_binary(n / 1.0, decimals: 4)

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d %H:%M")
  defp format_dt(_), do: ""

  defp preview_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp preview_args(args) when is_map(args) do
    args |> Enum.map(fn {k, v} -> "#{k}: #{truncate(inspect(v), 50)}" end) |> Enum.join(", ")
  end

  defp preview_args(other), do: inspect(other)

  defp summarize(text) do
    text = String.trim_trailing(to_string(text), "\n")
    lines = String.split(text, "\n")
    first = lines |> List.first("") |> truncate(120)
    if length(lines) > 1, do: "#{first} · #{length(lines)} lines", else: first
  end

  defp truncate(text, limit) when is_binary(text) do
    if byte_size(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "…"
  end

  defp truncate(other, limit), do: truncate(to_string(other), limit)
end
