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
        cwd: nil,
        sessions: [],
        recent_cwds: [],
        show_sessions: false,
        # New-session modal
        show_modal: false,
        modal_path: "",
        modal_path_valid: false,
        # Model settings
        provider: provider,
        model: model,
        mode: "react",
        available_models: [],
        models_loading: false,
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
        # Right-pane details stream: a chronological, append-only log of every
        # event in the session. Stored in REVERSE order (head = newest) for
        # O(1) prepends and O(1) "extend the last entry" merging during
        # streaming. `Enum.reverse/1` once at render time.
        details_stream: [],
        # The assistant message id that streaming events are currently
        # attributed to. Set in start_agent_run; cleared in :athena_done.
        pending_assistant_msg_id: nil,
        # Tool-UI panel (diffs / file reads / process output from tool events)
        show_diff_panel: false,
        diff_panel_log: [],
        diff_panel_idx: 0,
        # Git diff panel (git diff / git diff --staged output)
        show_git_panel: false,
        git_diff: nil,
        # Loading / status / errors
        page_loading: !connected?(socket),
        status: nil,
        error: nil
      )

    socket =
      if connected?(socket) do
        send(self(), {:load_models, provider})
        send(self(), :load_sessions)
        assign(socket, models_loading: true)
      else
        socket
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
      is_nil(socket.assigns.cwd) -> {:noreply, socket}
      true -> start_agent_run(socket, text)
    end
  end

  def handle_event("stop", _params, socket) do
    if pid = socket.assigns.streaming_task_pid do
      Process.exit(pid, :kill)
    end

    {:noreply,
     assign(socket,
       streaming: false,
       streaming_task_pid: nil,
       stream_text: "",
       stream_events: [],
       stream_tool_ui: %{},
       current_action: nil,
       pending_assistant_msg_id: nil
     )}
  end

  # --- New-session modal ---

  def handle_event("show_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: true, modal_path: "", modal_path_valid: false)}
  end

  def handle_event("cancel_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: false)}
  end

  def handle_event("modal_path_change", %{"path" => path}, socket) do
    path = String.trim(path)
    {:noreply, assign(socket, modal_path: path, modal_path_valid: path != "" and File.dir?(path))}
  end

  def handle_event("tab_complete", %{"path" => path}, socket) do
    completed = complete_path(path)
    valid = completed != "" and File.dir?(completed)

    socket =
      socket
      |> assign(modal_path: completed, modal_path_valid: valid)
      |> push_event("tab_fill", %{value: completed})

    {:noreply, socket}
  end

  def handle_event("create_session", %{"path" => path}, socket) do
    path = String.trim(path)

    if File.dir?(path) do
      Sessions.touch_recent(path)

      {:noreply,
       assign(socket,
         cwd: path,
         session_id: unique_id(),
         session_title: nil,
         session_created_at: DateTime.utc_now(),
         messages: [],
         ex_messages: [],
         tool_uis: %{},
         expanded_uis: MapSet.new(),
         details_stream: [],
         pending_assistant_msg_id: nil,
         diff_panel_log: [],
         diff_panel_idx: 0,
         git_diff: nil,
         status: nil,
         error: nil,
         show_modal: false,
         modal_path: "",
         modal_path_valid: false,
         recent_cwds: Sessions.list_recent()
       )}
    else
      {:noreply, assign(socket, modal_path_valid: false)}
    end
  end

  def handle_event("open_recent", %{"cwd" => cwd}, socket) do
    if File.dir?(cwd) do
      Sessions.touch_recent(cwd)
      sessions = Sessions.list_for_cwd(cwd)

      {:noreply,
       assign(socket,
         cwd: cwd,
         session_id: unique_id(),
         session_title: nil,
         session_created_at: DateTime.utc_now(),
         messages: [],
         ex_messages: [],
         tool_uis: %{},
         expanded_uis: MapSet.new(),
         details_stream: [],
         pending_assistant_msg_id: nil,
         diff_panel_log: [],
         diff_panel_idx: 0,
         git_diff: nil,
         status: nil,
         error: nil,
         sessions: sessions,
         show_sessions: sessions != [],
         recent_cwds: Sessions.list_recent()
       )}
    else
      {:noreply, assign(socket, error: "Directory no longer exists: #{cwd}")}
    end
  end

  def handle_event("remove_recent", %{"cwd" => cwd}, socket) do
    Sessions.remove_recent(cwd)
    {:noreply, assign(socket, recent_cwds: Sessions.list_recent())}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     assign(socket,
       session_id: unique_id(),
       session_title: nil,
       session_created_at: DateTime.utc_now(),
       messages: [],
       ex_messages: [],
       tool_uis: %{},
       expanded_uis: MapSet.new(),
       details_stream: [],
       pending_assistant_msg_id: nil,
       diff_panel_entry: nil,
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

    socket =
      if show do
        sessions =
          case socket.assigns.cwd do
            nil -> Sessions.list()
            cwd -> Sessions.list_for_cwd(cwd)
          end

        assign(socket, sessions: sessions)
      else
        socket
      end

    {:noreply, assign(socket, show_sessions: show)}
  end

  def handle_event("new_session", _params, socket) do
    # Start a new conversation in the same working directory
    {:noreply,
     assign(socket,
       session_id: unique_id(),
       session_title: nil,
       session_created_at: DateTime.utc_now(),
       messages: [],
       ex_messages: [],
       tool_uis: %{},
       expanded_uis: MapSet.new(),
       details_stream: [],
       pending_assistant_msg_id: nil,
       diff_panel_entry: nil,
       status: nil,
       error: nil
     )}
  end

  def handle_event("load_session", %{"id" => id}, socket) do
    case Sessions.load(id) do
      {:ok, data} ->
        cwd = Map.get(data, :cwd, socket.assigns.cwd)
        if cwd, do: Sessions.touch_recent(cwd)

        tool_uis = Map.get(data, :tool_uis, %{})

        details_stream =
          case Map.get(data, :details_stream) do
            nil -> hydrate_details_stream(data.display_messages, tool_uis)
            existing -> existing
          end

        {:noreply,
         assign(socket,
           session_id: data.id,
           session_title: data.title,
           session_created_at: Map.get(data, :created_at, DateTime.utc_now()),
           cwd: cwd,
           provider: data.provider,
           model: data.model,
           mode: data.mode,
           messages: data.display_messages,
           ex_messages: data.ex_messages,
           tool_uis: tool_uis,
           expanded_uis: MapSet.new(),
           details_stream: details_stream,
           pending_assistant_msg_id: nil,
           diff_panel_log: [],
           diff_panel_idx: 0,
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
        details_stream = hydrate_details_stream(forked_messages, socket.assigns.tool_uis)

        {:noreply,
         assign(socket,
           session_id: new_id,
           session_title: title,
           session_created_at: DateTime.utc_now(),
           messages: forked_messages,
           ex_messages: ex_messages,
           details_stream: details_stream,
           pending_assistant_msg_id: nil,
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

  def handle_event("focus_detail", %{"id" => tool_call_id}, socket) do
    {:noreply, push_event(socket, "focus-detail", %{tool_call_id: tool_call_id})}
  end

  def handle_event("toggle_diff_panel", _params, socket) do
    {:noreply, assign(socket, show_diff_panel: !socket.assigns.show_diff_panel)}
  end

  def handle_event("toggle_git_panel", _params, socket) do
    opening = !socket.assigns.show_git_panel
    git_diff = if opening, do: fetch_git_diff(socket.assigns.cwd), else: socket.assigns.git_diff
    {:noreply, assign(socket, show_git_panel: opening, git_diff: git_diff)}
  end

  def handle_event("refresh_git_diff", _params, socket) do
    {:noreply, assign(socket, git_diff: fetch_git_diff(socket.assigns.cwd))}
  end

  def handle_event("panel_prev", _params, socket) do
    idx = max(0, socket.assigns.diff_panel_idx - 1)
    {:noreply, assign(socket, diff_panel_idx: idx)}
  end

  def handle_event("panel_next", _params, socket) do
    idx = min(length(socket.assigns.diff_panel_log) - 1, socket.assigns.diff_panel_idx + 1)
    {:noreply, assign(socket, diff_panel_idx: idx)}
  end

  def handle_event("pin_to_panel", %{"id" => id}, socket) do
    log = socket.assigns.diff_panel_log
    idx = Enum.find_index(log, fn {log_id, _} -> log_id == id end)

    socket =
      if idx do
        assign(socket, diff_panel_idx: idx, show_diff_panel: true)
      else
        assign(socket, show_diff_panel: true)
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Internal messages
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_sessions, socket) do
    {:noreply, assign(socket, recent_cwds: Sessions.list_recent())}
  end

  def handle_info({:load_models, provider}, socket) do
    pid = self()
    Task.start(fn -> send(pid, {:models_loaded, fetch_models(provider)}) end)
    {:noreply, socket}
  end

  def handle_info({:models_loaded, models}, socket) do
    {:noreply, assign(socket, available_models: models, models_loading: false)}
  end

  def handle_info({:athena, {:content, text}}, socket) do
    msg_id = socket.assigns.pending_assistant_msg_id

    {:noreply,
     socket
     |> update(:stream_text, &(&1 <> text))
     |> update(:details_stream, &extend_or_prepend_text(&1, :assistant_text, msg_id, text))}
  end

  def handle_info({:athena, {:thinking, text}}, socket) do
    msg_id = socket.assigns.pending_assistant_msg_id

    {:noreply,
     update(socket, :details_stream, &extend_or_prepend_text(&1, :thinking, msg_id, text))}
  end

  def handle_info({:athena, {:tool_call, tc}}, socket) do
    event = %{type: :call, id: tc.id, name: tc.name, arguments: tc.arguments}
    action = action_label(tc.name, tc.arguments)
    msg_id = socket.assigns.pending_assistant_msg_id

    detail =
      new_detail(:tool_call, msg_id, %{
        tool_call_id: tc.id,
        name: tc.name,
        arguments: tc.arguments
      })

    {:noreply,
     socket
     |> update(:stream_events, &(&1 ++ [event]))
     |> update(:details_stream, &[detail | &1])
     |> assign(current_action: action)}
  end

  def handle_info({:athena, {:tool_result, tr}}, socket) do
    content = to_string(tr.content)
    is_error = tr.is_error || false

    event = %{
      type: :result,
      tool_call_id: tr.tool_call_id,
      content: content,
      is_error: is_error
    }

    msg_id = socket.assigns.pending_assistant_msg_id

    detail =
      new_detail(:tool_result, msg_id, %{
        tool_call_id: tr.tool_call_id,
        content: content,
        is_error: is_error
      })

    {:noreply,
     socket
     |> update(:stream_events, &(&1 ++ [event]))
     |> update(:details_stream, &[detail | &1])
     |> assign(current_action: nil)}
  end

  def handle_info(
        {:athena, {:tool_ui, %{tool_call_id: id, kind: kind, payload: payload}}},
        socket
      ) do
    ui_entry = build_ui_entry(kind, payload, socket.assigns.cwd)
    msg_id = socket.assigns.pending_assistant_msg_id
    detail = new_detail(:tool_ui, msg_id, %{tool_call_id: id, ui: ui_entry})

    {:noreply,
     socket
     |> update(:stream_tool_ui, &Map.put(&1, id, ui_entry))
     |> update(:details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:iteration, n}}, socket) do
    detail = new_detail(:iteration, socket.assigns.pending_assistant_msg_id, %{n: n})
    {:noreply, update(socket, :details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:compaction, data}}, socket) do
    detail = new_detail(:compaction, socket.assigns.pending_assistant_msg_id, data)
    {:noreply, update(socket, :details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:subagent_spawn, data}}, socket) do
    detail = new_detail(:subagent_spawn, socket.assigns.pending_assistant_msg_id, data)
    {:noreply, update(socket, :details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:subagent_result, data}}, socket) do
    detail = new_detail(:subagent_result, socket.assigns.pending_assistant_msg_id, data)
    {:noreply, update(socket, :details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:structured_retry, data}}, socket) do
    detail = new_detail(:structured_retry, socket.assigns.pending_assistant_msg_id, data)
    {:noreply, update(socket, :details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:usage, usage}}, socket) do
    detail = new_detail(:usage, socket.assigns.pending_assistant_msg_id, %{usage: usage})
    {:noreply, update(socket, :details_stream, &[detail | &1])}
  end

  def handle_info({:athena, {:error, reason}}, socket) do
    detail =
      new_detail(:error, socket.assigns.pending_assistant_msg_id, %{reason: inspect(reason)})

    {:noreply,
     socket
     |> assign(error: inspect(reason))
     |> update(:details_stream, &[detail | &1])}
  end

  def handle_info({:athena, _other}, socket), do: {:noreply, socket}

  def handle_info({:athena_done, _result}, %{assigns: %{streaming: false}} = socket),
    do: {:noreply, socket}

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

    assistant_msg_id = socket.assigns.pending_assistant_msg_id || unique_id()

    assistant_msg = %{
      id: assistant_msg_id,
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
        streaming_task_pid: nil,
        stream_text: "",
        stream_events: [],
        stream_tool_ui: %{},
        current_action: nil,
        pending_assistant_msg_id: nil,
        status: status,
        error: nil,
        session_title: title
      )

    socket =
      if socket.assigns.show_git_panel do
        assign(socket, git_diff: fetch_git_diff(socket.assigns.cwd))
      else
        socket
      end

    save_session(socket)
    {:noreply, socket}
  end

  def handle_info({:athena_error, _reason}, %{assigns: %{streaming: false}} = socket),
    do: {:noreply, socket}

  def handle_info({:athena_error, reason}, socket) do
    {:noreply,
     assign(socket,
       streaming: false,
       streaming_task_pid: nil,
       current_action: nil,
       error: inspect(reason)
     )}
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, max_diff_lines: @max_diff_lines)

    ~H"""
    <%= if @page_loading do %>
      <div class="page-loading">
        <div class="page-loading-spinner"></div>
        <div class="page-loading-text">Connecting…</div>
      </div>
    <% else %>
    <div class="app">
      <%!-- New-session modal --%>
      <%= if @show_modal do %>
        <div class="modal-overlay" phx-window-keydown="cancel_modal" phx-key="Escape">
          <div class="modal">
            <div class="modal-header">
              <span class="modal-title">New session</span>
              <button type="button" class="modal-close" phx-click="cancel_modal">×</button>
            </div>
            <form phx-change="modal_path_change" phx-submit="create_session">
              <div class="modal-body">
                <label class="field-label">Working directory</label>
                <input
                  id="modal-path-input"
                  class={"field-input#{if @modal_path != "" and not @modal_path_valid, do: " field-input--error", else: ""}"}
                  type="text"
                  name="path"
                  value={@modal_path}
                  placeholder="/home/you/my-project  (Tab to complete)"
                  phx-hook="PathInput"
                />
                <div class="field-hint">
                  <%= cond do %>
                    <% @modal_path == "" -> %>
                      Enter a path, or press Tab to autocomplete.
                    <% @modal_path_valid -> %>
                      <span class="hint-ok">✓ Directory found</span>
                    <% true -> %>
                      <span class="hint-err">Directory not found</span>
                  <% end %>
                </div>
              </div>
              <div class="modal-footer">
                <button type="button" class="btn-secondary" phx-click="cancel_modal">Cancel</button>
                <button
                  type="submit"
                  class={"btn-create#{if not @modal_path_valid, do: " btn-create--disabled", else: ""}"}
                  disabled={not @modal_path_valid}
                >
                  Open →
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%!-- Sidebar --%>
      <aside class="sidebar">
        <div class="sidebar-logo">
          <div class="sidebar-logo-brand">
            <img class="sidebar-logo-img" src="/assets/exathena-logo.png" alt="ExAthena logo" />
            <span class="logo-text">ExAthena</span>
          </div>
          <button class="btn-plus" phx-click="show_modal" title="New session">+</button>
        </div>

        <%!-- Active project --%>
        <%= if @cwd do %>
          <div class="cwd-bar">
            <span class="cwd-icon">⊡</span>
            <span class="cwd-name" title={@cwd}>{Path.basename(@cwd)}</span>
            <span class="cwd-path">{@cwd}</span>
          </div>
        <% end %>

        <div class="sidebar-section">
          <label class="field-label">Provider</label>
          <select class="field-select" phx-change="set_provider" name="value">
            <option :for={{label, val} <- @providers} value={val} selected={@provider == val}>
              {label}
            </option>
          </select>
        </div>

        <div class="sidebar-section">
          <label class="field-label">
            Model
            <%= if @models_loading do %>
              <span class="field-loading-dot"></span>
            <% end %>
          </label>
          <%= if @models_loading do %>
            <div class="field-loading">fetching models…</div>
          <% else %>
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

        <%!-- Recent projects --%>
        <%= if @recent_cwds != [] do %>
          <div class="sidebar-section">
            <label class="field-label">Recent</label>
            <div class="sidebar-recents">
              <div
                :for={r <- @recent_cwds}
                class={"sidebar-recent#{if r.cwd == @cwd, do: " sidebar-recent--active", else: ""}"}
              >
                <button
                  class="sidebar-recent-btn"
                  phx-click="open_recent"
                  phx-value-cwd={r.cwd}
                  title={r.cwd}
                >
                  <span class="sidebar-recent-name">{r.name}</span>
                  <span class="sidebar-recent-path">{r.cwd}</span>
                </button>
                <button
                  class="sidebar-recent-rm"
                  phx-click="remove_recent"
                  phx-value-cwd={r.cwd}
                  title="Remove"
                >×</button>
              </div>
            </div>
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
      <main class="chat-main" id="chat-main" phx-hook="SplitResize">
        <div class="panel-toggles">
          <button
            class={"btn-panel-toggle#{if @show_diff_panel, do: " btn-panel-toggle--active", else: ""}"}
            phx-click="toggle_diff_panel"
            title={if @show_diff_panel, do: "Hide tool panel", else: "Show tool panel"}
          >⊟</button>
          <button
            class={"btn-panel-toggle#{if @show_git_panel, do: " btn-panel-toggle--active", else: ""}"}
            phx-click="toggle_git_panel"
            title={if @show_git_panel, do: "Hide git diff", else: "Show git diff"}
          >±</button>
        </div>

        <div class="messages" id="messages" phx-hook="ScrollToBottom">
          <%= if @messages == [] and not @streaming do %>
            <div class="empty-state">
              <div class="empty-icon">◈</div>
              <div class="empty-title">ExAthena</div>
              <%= if is_nil(@cwd) do %>
                <div class="empty-sub">Open a project folder to start a session</div>
                <%= if @recent_cwds != [] do %>
                  <div class="recent-projects">
                    <div class="recent-header">Recent projects</div>
                    <div :for={r <- @recent_cwds} class="recent-item">
                      <button class="recent-open" phx-click="open_recent" phx-value-cwd={r.cwd}>
                        <span class="recent-name">{r.name}</span>
                        <span class="recent-path">{r.cwd}</span>
                      </button>
                      <button class="recent-remove" phx-click="remove_recent" phx-value-cwd={r.cwd} title="Remove from list">×</button>
                    </div>
                  </div>
                <% else %>
                  <div class="empty-hint">Click + to open a folder</div>
                <% end %>
              <% else %>
                <div class="empty-sub">{@provider} · {@mode}</div>
              <% end %>
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

        <div class="chat-divider" id="chat-divider" aria-label="Resize panes" role="separator"></div>

        <div class="details-pane" id="details-pane" phx-hook="ScrollToBottom">
          <.details_pane stream={@details_stream} max_diff_lines={@max_diff_lines} />
        </div>

        <div class="input-bar">
          <form class="input-form" phx-submit="send">
            <textarea
              id="chat-input"
              class="input-textarea"
              name="text"
              placeholder={if is_nil(@cwd), do: "Open a project folder first (+ button)", else: "Message ExAthena… (Enter to send, Shift+Enter for newline)"}
              disabled={@streaming or is_nil(@cwd)}
              phx-hook="SubmitOnEnter"
            ></textarea>
            <button
              class={if @streaming, do: "btn-stop", else: "btn-send#{if is_nil(@cwd), do: " btn-send--disabled", else: ""}"}
              type={if @streaming, do: "button", else: "submit"}
              phx-click={if @streaming, do: "stop"}
              disabled={not @streaming and is_nil(@cwd)}
            >
              <%= if @streaming do %>
                ■
              <% else %>
                ↑
              <% end %>
            </button>
          </form>
        </div>
      </main>

      <%!-- Right-side panels column --%>
      <%= if @show_diff_panel or @show_git_panel do %>
        <div class="panels-col">
          <%!-- Tool-UI panel --%>
          <%= if @show_diff_panel do %>
            <%
              {_panel_id, panel_entry} = Enum.at(@diff_panel_log, @diff_panel_idx, {nil, nil})
              panel_total = length(@diff_panel_log)
            %>
            <div class="diff-panel">
              <div class="diff-panel-header">
                <span class="diff-panel-title">
                  <%= cond do %>
                    <% is_nil(panel_entry) -> %>
                      Changes
                    <% panel_entry[:kind] == :diff -> %>
                      {panel_entry[:path]}
                    <% panel_entry[:kind] == :file -> %>
                      {panel_entry[:path]}
                    <% panel_entry[:kind] == :process -> %>
                      {panel_entry[:command]}
                    <% true -> %>
                      Changes
                  <% end %>
                </span>
                <%= if panel_total > 1 do %>
                  <div class="diff-panel-nav">
                    <button class="diff-panel-nav-btn" phx-click="panel_prev" disabled={@diff_panel_idx == 0}>‹</button>
                    <span class="diff-panel-nav-pos">{@diff_panel_idx + 1}/{panel_total}</span>
                    <button class="diff-panel-nav-btn" phx-click="panel_next" disabled={@diff_panel_idx == panel_total - 1}>›</button>
                  </div>
                <% end %>
                <button class="diff-panel-close" phx-click="toggle_diff_panel" title="Close">×</button>
              </div>
              <div class="diff-panel-body">
                <%= if panel_entry do %>
                  <.tool_ui_panel ui={panel_entry} />
                <% else %>
                  <div class="diff-panel-empty">No output yet — run a command to see results here.</div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Git diff panel --%>
          <%= if @show_git_panel do %>
            <div class="git-panel">
              <div class="git-panel-header">
                <span class="git-panel-title">git diff</span>
                <button class="git-panel-refresh" phx-click="refresh_git_diff" title="Refresh">↺</button>
                <button class="git-panel-close" phx-click="toggle_git_panel" title="Close">×</button>
              </div>
              <div class="git-panel-body">
                <%= cond do %>
                  <% is_nil(@git_diff) -> %>
                    <div class="diff-panel-empty">Not a git repository or git not available.</div>
                  <% @git_diff == [] -> %>
                    <div class="diff-panel-empty">Working tree clean — no changes.</div>
                  <% true -> %>
                    <div class="git-diff-output">
                      <%= for {kind, line} <- @git_diff do %>
                        <div class={"gdiff-line gdiff-#{kind}"}>{line}</div>
                      <% end %>
                    </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    <% end %>
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

    results_by_id =
      assigns.events |> Enum.filter(&(&1.type == :result)) |> Map.new(&{&1.tool_call_id, &1})

    assigns = assign(assigns, calls: calls, results_by_id: results_by_id)

    ~H"""
    <div class="tool-events tool-events--compact">
      <button
        :for={call <- @calls}
        type="button"
        class="tool-one-liner"
        phx-click="focus_detail"
        phx-value-id={call.id}
        title="Show details on the right"
      >
        <span class="tool-arrow">→</span>
        <span class="tool-name">{call.name}</span>
        <span class="tool-args">{preview_args(call.arguments)}</span>
        <%= if result = Map.get(@results_by_id, call.id) do %>
          <span class={"tool-result-inline#{if result.is_error, do: " tool-result-inline--error", else: ""}"}>
            <span class="tool-arrow">{if result.is_error, do: "✗", else: "←"}</span>
            <span class="tool-result-content">{summarize(result.content)}</span>
          </span>
        <% end %>
      </button>
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
        <%= for {kind, line} <- @ui.lines do %>
          <%= if kind == :gap do %>
            <div class="diff-gap">{line}</div>
          <% else %>
            <div class={"diff-line diff-#{kind}"}>
              <span class="diff-mark">{diff_mark(kind)}</span>
              <span class="diff-text">{line}</span>
            </div>
          <% end %>
        <% end %>
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
  # Right-pane: details_stream renderer
  # ---------------------------------------------------------------------------

  defp details_pane(%{stream: []} = assigns) do
    ~H"""
    <div class="details-empty">
      <div class="details-empty-title">Activity</div>
      <div class="details-empty-sub">Tool calls, results, and thinking will stream here.</div>
    </div>
    """
  end

  defp details_pane(assigns) do
    assigns = assign(assigns, :entries, Enum.reverse(assigns.stream))

    ~H"""
    <div class="details-list" id="details-list">
      <.detail_entry :for={e <- @entries} entry={e} />
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :user_text} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--user" id={"detail-#{@e.id}"}>
      <div class="detail-label">you</div>
      <div class="detail-text">{@e.payload.text}</div>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :assistant_text} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--assistant" id={"detail-#{@e.id}"}>
      <div class="detail-label">assistant</div>
      <div class="detail-text" style="white-space: pre-wrap">{@e.payload.text}</div>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :thinking} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--thinking" id={"detail-#{@e.id}"}>
      <div class="detail-label">thinking</div>
      <div class="detail-text" style="white-space: pre-wrap">{@e.payload.text}</div>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :tool_call} = e} = assigns) do
    assigns =
      assign(assigns,
        e: e,
        args_pretty: format_args(e.payload.arguments)
      )

    ~H"""
    <div
      class="detail-entry detail-entry--tool-call"
      id={"detail-#{@e.id}"}
      data-tool-call-id={@e.payload.tool_call_id}
    >
      <div class="detail-label">
        <span class="tool-arrow">→</span> {@e.payload.name}
      </div>
      <pre class="detail-pre">{@args_pretty}</pre>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :tool_result} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div
      class={"detail-entry detail-entry--tool-result#{if @e.payload.is_error, do: " detail-entry--error", else: ""}"}
      id={"detail-#{@e.id}"}
      data-tool-call-id={@e.payload.tool_call_id}
    >
      <div class="detail-label">
        <span class="tool-arrow">{if @e.payload.is_error, do: "✗", else: "←"}</span>
        {if @e.payload.is_error, do: "error", else: "result"}
      </div>
      <pre class="detail-pre">{@e.payload.content}</pre>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :tool_ui} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div
      class="detail-entry detail-entry--tool-ui"
      id={"detail-#{@e.id}"}
      data-tool-call-id={@e.payload.tool_call_id}
    >
      <.tool_ui_panel ui={@e.payload.ui} />
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :iteration} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--iteration" id={"detail-#{@e.id}"}>
      <span class="detail-divider-line"></span>
      <span class="detail-divider-label">iteration {@e.payload.n}</span>
      <span class="detail-divider-line"></span>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :compaction} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--meta" id={"detail-#{@e.id}"}>
      <div class="detail-label">compaction</div>
      <div class="detail-text">
        {Map.get(@e.payload, :before)} → {Map.get(@e.payload, :after)} tokens
        <%= if reason = Map.get(@e.payload, :reason) do %>
          · {inspect(reason)}
        <% end %>
      </div>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :subagent_spawn} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--subagent" id={"detail-#{@e.id}"}>
      <div class="detail-label">subagent spawn · {inspect(Map.get(@e.payload, :id))}</div>
      <pre class="detail-pre">{Map.get(@e.payload, :prompt, "")}</pre>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :subagent_result} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--subagent" id={"detail-#{@e.id}"}>
      <div class="detail-label">subagent result · {inspect(Map.get(@e.payload, :id))}</div>
      <pre class="detail-pre">{Map.get(@e.payload, :text, "")}</pre>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :structured_retry} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--meta" id={"detail-#{@e.id}"}>
      <div class="detail-label">structured-retry attempt {Map.get(@e.payload, :attempt)}</div>
      <pre class="detail-pre">{inspect(Map.get(@e.payload, :error))}</pre>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :usage} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--meta" id={"detail-#{@e.id}"}>
      <div class="detail-label">usage</div>
      <pre class="detail-pre">{inspect(Map.get(@e.payload, :usage))}</pre>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :error} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--error" id={"detail-#{@e.id}"}>
      <div class="detail-label">⚠ error</div>
      <div class="detail-text">{Map.get(@e.payload, :reason)}</div>
    </div>
    """
  end

  defp detail_entry(assigns), do: ~H""

  defp format_args(args) when is_map(args) do
    case Jason.encode(args, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(args, pretty: true, limit: :infinity)
    end
  end

  defp format_args(other), do: inspect(other, pretty: true)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_agent_run(socket, text) do
    pid = self()
    provider = socket.assigns.provider
    model = socket.assigns.model
    mode = socket.assigns.mode

    user_msg = %{id: unique_id(), role: :user, text: text, tool_events: [], status: nil}
    assistant_msg_id = unique_id()
    new_ex_msg = Messages.user(text)
    ex_messages = socket.assigns.ex_messages ++ [new_ex_msg]

    {:ok, task_pid} =
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
          |> maybe_put_cwd(socket.assigns.cwd)

        case ExAthena.run(nil, opts) do
          {:ok, result} -> send(pid, {:athena_done, result})
          {:error, reason} -> send(pid, {:athena_error, reason})
        end
      end)

    user_detail = new_detail(:user_text, user_msg.id, %{text: text})

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [user_msg],
       ex_messages: ex_messages,
       streaming: true,
       streaming_task_pid: task_pid,
       stream_text: "",
       stream_events: [],
       stream_tool_ui: %{},
       diff_panel_log: [],
       diff_panel_idx: 0,
       current_action: nil,
       pending_assistant_msg_id: assistant_msg_id,
       details_stream: [user_detail | socket.assigns.details_stream],
       error: nil
     )}
  end

  defp save_session(socket) do
    a = socket.assigns

    Sessions.save(%{
      id: a.session_id,
      title: a.session_title,
      cwd: a.cwd,
      provider: a.provider,
      model: a.model,
      mode: a.mode,
      created_at: a.session_created_at,
      updated_at: DateTime.utc_now(),
      display_messages: a.messages,
      ex_messages: a.ex_messages,
      tool_uis: a.tool_uis,
      details_stream: a.details_stream
    })
  end

  # ---------------------------------------------------------------------------
  # Details-stream helpers
  # ---------------------------------------------------------------------------

  defp new_detail(type, message_id, payload) do
    %{
      id: unique_id(),
      type: type,
      message_id: message_id,
      payload: payload
    }
  end

  # Stream is stored newest-first. If the head matches the same type and
  # message_id (e.g. successive :content deltas during one turn), extend the
  # existing entry's text instead of creating a new one.
  defp extend_or_prepend_text(stream, _type, _msg_id, ""), do: stream

  defp extend_or_prepend_text(
         [%{type: t, message_id: m, payload: %{text: existing} = pl} = head | rest],
         t,
         m,
         text
       ) do
    [%{head | payload: %{pl | text: existing <> text}} | rest]
  end

  defp extend_or_prepend_text(stream, type, msg_id, text) do
    [new_detail(type, msg_id, %{text: text}) | stream]
  end

  # Rebuild details_stream from legacy persisted state (display messages +
  # tool_uis). Used when loading a session that pre-dates details_stream
  # persistence. Returns newest-first.
  defp hydrate_details_stream(messages, tool_uis) when is_list(messages) do
    messages
    |> Enum.flat_map(&message_to_details(&1, tool_uis))
    |> Enum.reverse()
  end

  defp hydrate_details_stream(_, _), do: []

  defp message_to_details(%{role: :user, id: id, text: text}, _tool_uis) do
    [new_detail(:user_text, id, %{text: text})]
  end

  defp message_to_details(%{role: :assistant, id: id, text: text, tool_events: events}, tool_uis) do
    calls = Enum.filter(events, &(&1.type == :call))

    results_by_id =
      events |> Enum.filter(&(&1.type == :result)) |> Map.new(&{&1.tool_call_id, &1})

    tool_details =
      Enum.flat_map(calls, fn call ->
        call_detail =
          new_detail(:tool_call, id, %{
            tool_call_id: call.id,
            name: call.name,
            arguments: call.arguments
          })

        result_detail =
          case Map.get(results_by_id, call.id) do
            nil ->
              []

            r ->
              [
                new_detail(:tool_result, id, %{
                  tool_call_id: call.id,
                  content: r.content,
                  is_error: r.is_error
                })
              ]
          end

        ui_detail =
          case Map.get(tool_uis, call.id) do
            nil -> []
            ui -> [new_detail(:tool_ui, id, %{tool_call_id: call.id, ui: ui})]
          end

        [call_detail] ++ result_detail ++ ui_detail
      end)

    text_detail =
      if text && text != "",
        do: [new_detail(:assistant_text, id, %{text: text})],
        else: []

    tool_details ++ text_detail
  end

  defp message_to_details(_, _), do: []

  defp build_ui_entry(:diff, %{path: path, before: before, after: after_text}, cwd) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_text, "\n")

    all_lines =
      List.myers_difference(before_lines, after_lines)
      |> Enum.flat_map(fn
        {:eq, lines} -> Enum.map(lines, &{:eq, &1})
        {:ins, lines} -> Enum.map(lines, &{:ins, &1})
        {:del, lines} -> Enum.map(lines, &{:del, &1})
      end)

    changed = Enum.count(all_lines, fn {k, _} -> k != :eq end)

    if changed == 0 do
      nil
    else
      total = length(all_lines)
      ctx = 3

      keep =
        all_lines
        |> Enum.with_index()
        |> Enum.filter(fn {{k, _}, _} -> k != :eq end)
        |> Enum.flat_map(fn {_, i} -> Enum.to_list(max(0, i - ctx)..min(total - 1, i + ctx)) end)
        |> MapSet.new()

      visible =
        all_lines
        |> Enum.with_index()
        |> Enum.reduce({[], nil}, fn {{kind, line}, i}, {acc, last} ->
          if MapSet.member?(keep, i) do
            gap =
              case last do
                nil when i > 0 -> [{:gap, "… #{i} lines"}]
                prev when i > prev + 1 -> [{:gap, "… #{i - prev - 1} lines"}]
                _ -> []
              end

            {acc ++ gap ++ [{kind, line}], i}
          else
            {acc, last}
          end
        end)
        |> elem(0)

      display = Enum.take(visible, @max_diff_lines)

      %{
        kind: :diff,
        path: relpath(path, cwd),
        lines: display,
        total_lines: total,
        changed_lines: changed,
        shown: length(visible),
        truncated: length(visible) > @max_diff_lines
      }
    end
  end

  defp build_ui_entry(
         :process,
         %{command: cmd, exit_code: code, stdout: out, duration_ms: ms},
         _cwd
       ) do
    %{
      kind: :process,
      command: cmd,
      exit_code: code,
      stdout: truncate(out, 10_000),
      duration_ms: ms
    }
  end

  defp build_ui_entry(:file, %{path: path, content: content}, cwd) do
    %{kind: :file, path: relpath(path, cwd), content: truncate(content, 8_000)}
  end

  defp build_ui_entry(_kind, _payload, _cwd), do: nil

  defp relpath(path, nil), do: path
  defp relpath(path, cwd), do: Path.relative_to(path, cwd)

  defp fetch_git_diff(nil), do: nil

  defp fetch_git_diff(cwd) do
    try do
      {unstaged, _} = System.cmd("git", ["diff", "--color=never"], cd: cwd)
      {staged, _} = System.cmd("git", ["diff", "--staged", "--color=never"], cd: cwd)
      combined = [unstaged, staged] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
      if combined == "", do: [], else: parse_git_diff(combined)
    rescue
      _ -> nil
    end
  end

  defp parse_git_diff(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "diff --git") -> {:header, line}
        String.starts_with?(line, "index ") -> {:meta, line}
        String.starts_with?(line, "new file") -> {:meta, line}
        String.starts_with?(line, "deleted file") -> {:meta, line}
        String.starts_with?(line, "Binary files") -> {:meta, line}
        String.starts_with?(line, "--- ") -> {:file_a, line}
        String.starts_with?(line, "+++ ") -> {:file_b, line}
        String.starts_with?(line, "@@") -> {:hunk, line}
        String.starts_with?(line, "+") -> {:ins, line}
        String.starts_with?(line, "-") -> {:del, line}
        true -> {:ctx, line}
      end
    end)
  end

  defp diff_mark(:ins), do: "+"
  defp diff_mark(:del), do: "−"
  defp diff_mark(:eq), do: " "
  defp diff_mark(:gap), do: ""

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

  defp maybe_put_cwd(opts, cwd) when is_binary(cwd), do: Keyword.put(opts, :cwd, cwd)
  defp maybe_put_cwd(opts, _), do: opts

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

  defp complete_path(""), do: ""

  defp complete_path(path) do
    {dir, prefix} =
      if String.ends_with?(path, "/") do
        {path, ""}
      else
        {Path.dirname(path), Path.basename(path)}
      end

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.sort()
        |> case do
          [] ->
            path

          [single] ->
            Path.join(dir, single) <> "/"

          many ->
            cp = common_prefix(many)
            filled = if cp == "" or cp == prefix, do: hd(many), else: cp
            Path.join(dir, filled)
        end

      _ ->
        path
    end
  end

  defp common_prefix([]), do: ""
  defp common_prefix([s]), do: s

  defp common_prefix([h | t]) do
    Enum.reduce(t, h, fn s, acc ->
      acc
      |> String.graphemes()
      |> Enum.zip(String.graphemes(s))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map_join(&elem(&1, 0))
    end)
  end
end
