defmodule ExAthena.Web.Live.ChatLive do
  use Phoenix.LiveView

  alias ExAthena.Messages
  alias ExAthena.Messages.ContentPart
  alias ExAthena.Web.Sessions
  alias Phoenix.LiveView.JS

  @providers [
    {"llama.cpp", "llamacpp"},
    {"Ollama", "ollama"},
    {"EXO", "exo"},
    {"Claude / Anthropic", "claude"},
    {"Claude Code", "claude_code"},
    {"OpenAI-compatible", "openai_compatible"},
    {"Gemini", "gemini"},
    {"OpenRouter", "openrouter"}
  ]
  @modes [
    {"ReAct", "react"},
    {"Plan & Solve", "plan_and_solve"},
    {"Reflexion", "reflexion"},
    {"Orchestrate", "orchestrate"}
  ]

  # How many diff lines to show before truncating
  @max_diff_lines 300

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(params, _session, socket) do
    provider = default_provider()
    model = default_model(provider)
    # `/c/:session_id` carries a stable id across reconnects; `/` is a fresh id
    # (stamped into the URL by handle_params once connected).
    url_session_id = params["session_id"]
    session_id = url_session_id || unique_id()

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
        queue_slots: current_queue_slots(provider),
        mode: "react",
        available_models: [],
        # Current text in the model search box (server-filtered dropdown) and
        # whether the dropdown is open (focused). When closed the box shows the
        # selected `model`; when open it shows `model_query` as a search field.
        model_query: "",
        model_open: false,
        models_loading: false,
        providers: @providers,
        modes: @modes,
        # Conversation
        messages: [],
        pending_images: [],
        streaming: false,
        stream_text: "",
        stream_events: [],
        stream_tool_ui: %{},
        current_action: nil,
        # When the run calls the `ask_user` tool it pauses and we surface the
        # question here: %{tool_call_id, question, options}. Non-nil means the
        # loop is blocked waiting for the user — the input is re-enabled even
        # though `streaming` is still true.
        awaiting_question: nil,
        ex_messages: [],
        # Provider-side conversation id (e.g. Claude Code CLI session) from
        # the last Result — passed back as `resume:` on the next run.
        provider_session_id: nil,
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
        # Details pane: tabbed (:overview | :log | :git | :terminal) plus a
        # visibility toggle.
        details_tab: :overview,
        show_details: true,
        # Embedded terminals (Terminal tab). `terminals` is an ordered list
        # of %{id, title, status}; each renders its own xterm.js instance,
        # output streams to the client via push_event (no server buffer).
        terminals: [],
        active_terminal: nil,
        # Live orchestration snapshot (ExAthena.Orchestrator.Coordinator) for
        # the Overview tab. One coordinator per run; orchestrator_sid scopes
        # incoming updates to the current run.
        orchestrator: nil,
        orchestrator_sid: nil,
        # Agent id (as string) whose focus view is open in Overview; nil = tree.
        overview_focus: nil,
        # Expanded Overview sections ("task:<id>", "transcript:<agent>").
        # Server-owned: the 100 ms snapshot patches would strip a native
        # <details open> the user toggled client-side.
        ov_expanded: MapSet.new(),
        # Expanded chat thinking blocks (keyed by detail entry id) — same
        # morphdom problem: streaming re-renders strip user-toggled state.
        chat_expanded: MapSet.new(),
        gpu_stats: nil,
        # Git diff output (rendered in the Git tab)
        git_diff: nil,
        # Loading / status / errors
        page_loading: !connected?(socket),
        status: nil,
        # Pid bookkeeping retained for legacy assigns; run control now flows
        # through RunServer keyed by session_id, not a captured task pid.
        streaming_task_pid: nil,
        error: nil
      )

    socket =
      if connected?(socket) do
        send(self(), :load_sessions)
        # Re-attach to an in-flight run (reconnect) or reopen a persisted
        # session for this URL, before loading models for the resolved provider.
        socket = maybe_restore(socket, url_session_id)
        send(self(), {:load_models, socket.assigns.provider})
        assign(socket, models_loading: true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Stamp the stable session id into the URL once connected so a websocket
    # reconnect re-mounts with it (and can re-attach to a running RunServer).
    if is_nil(params["session_id"]) and connected?(socket) do
      {:noreply, push_session_url(socket)}
    else
      {:noreply, socket}
    end
  end

  # Connected-mount restore: re-attach to a live run if one is in flight for
  # this session id, otherwise reopen the persisted session. A `/` mount (no
  # url id) stays fresh — the URL is patched by handle_params.
  defp maybe_restore(socket, nil), do: socket

  defp maybe_restore(socket, id) do
    if ExAthena.Web.RunServer.running?(id) do
      reattach_run(socket, id)
    else
      case Sessions.load(id) do
        {:ok, data} -> assign_session_data(socket, data)
        {:error, _} -> socket
      end
    end
  end

  defp reattach_run(socket, id) do
    socket =
      case Sessions.load(id) do
        {:ok, data} -> assign_session_data(socket, data)
        {:error, _} -> socket
      end

    case ExAthena.Web.RunServer.attach(id, self()) do
      {:ok, snap} ->
        socket
        |> assign(
          streaming: snap.streaming,
          stream_text: snap.stream_text,
          current_action: snap.current_action,
          awaiting_question: snap.awaiting_question,
          pending_assistant_msg_id: snap.pending_assistant_msg_id
        )
        |> resubscribe_coordinator(snap.run_sid)

      {:error, :not_running} ->
        socket
    end
  end

  defp resubscribe_coordinator(socket, nil), do: socket

  defp resubscribe_coordinator(socket, run_sid) do
    case ExAthena.Orchestrator.Coordinator.subscribe(run_sid, self()) do
      {:ok, snapshot} -> assign(socket, orchestrator: snapshot, orchestrator_sid: run_sid)
      {:error, _} -> assign(socket, orchestrator_sid: run_sid)
    end
  end

  # ---------------------------------------------------------------------------
  # User events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      # A run is paused on an `ask_user` question — route this as the answer
      # back into the blocked tool instead of starting a new run.
      socket.assigns.awaiting_question != nil and text != "" -> answer_question(socket, text)
      text == "" and socket.assigns.pending_images == [] -> {:noreply, socket}
      socket.assigns.streaming -> {:noreply, socket}
      is_nil(socket.assigns.cwd) -> {:noreply, socket}
      true -> start_agent_run(socket, text)
    end
  end

  def handle_event("answer_option", %{"option" => value}, socket) do
    # phx-value-option (not -value): a <button>'s native empty value property
    # would otherwise override phx-value-value and send a blank answer.
    if socket.assigns.awaiting_question,
      do: answer_question(socket, value),
      else: {:noreply, socket}
  end

  def handle_event("attach_image", %{"data" => data, "type" => type}, socket) do
    image = %{data: data, media_type: type}
    {:noreply, update(socket, :pending_images, &(&1 ++ [image]))}
  end

  def handle_event("remove_image", %{"index" => idx}, socket) do
    idx = if is_binary(idx), do: String.to_integer(idx), else: idx
    {:noreply, assign(socket, pending_images: List.delete_at(socket.assigns.pending_images, idx))}
  end

  def handle_event("stop", _params, socket) do
    ExAthena.Web.RunServer.stop_run(socket.assigns.session_id)

    {:noreply,
     assign(socket,
       streaming: false,
       streaming_task_pid: nil,
       stream_text: "",
       stream_events: [],
       stream_tool_ui: %{},
       current_action: nil,
       awaiting_question: nil,
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
       socket
       |> assign(
         cwd: path,
         session_id: unique_id(),
         session_title: nil,
         session_created_at: DateTime.utc_now(),
         messages: [],
         pending_images: [],
         ex_messages: [],
         tool_uis: %{},
         expanded_uis: MapSet.new(),
         details_stream: [],
         pending_assistant_msg_id: nil,
         git_diff: nil,
         status: nil,
         error: nil,
         show_modal: false,
         modal_path: "",
         modal_path_valid: false,
         recent_cwds: Sessions.list_recent()
       )
       |> push_session_url()}
    else
      {:noreply, assign(socket, modal_path_valid: false)}
    end
  end

  def handle_event("open_recent", %{"cwd" => cwd}, socket) do
    if File.dir?(cwd) do
      Sessions.touch_recent(cwd)
      sessions = Sessions.list_for_cwd(cwd)

      {:noreply,
       socket
       |> assign(
         cwd: cwd,
         session_id: unique_id(),
         session_title: nil,
         session_created_at: DateTime.utc_now(),
         messages: [],
         pending_images: [],
         ex_messages: [],
         tool_uis: %{},
         expanded_uis: MapSet.new(),
         details_stream: [],
         pending_assistant_msg_id: nil,
         git_diff: nil,
         status: nil,
         error: nil,
         sessions: sessions,
         show_sessions: sessions != [],
         recent_cwds: Sessions.list_recent()
       )
       |> push_session_url()}
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
     socket
     |> assign(
       session_id: unique_id(),
       session_title: nil,
       session_created_at: DateTime.utc_now(),
       messages: [],
       pending_images: [],
       ex_messages: [],
       tool_uis: %{},
       expanded_uis: MapSet.new(),
       details_stream: [],
       pending_assistant_msg_id: nil,
       status: nil,
       error: nil,
       stream_text: "",
       stream_events: [],
       stream_tool_ui: %{},
       current_action: nil
     )
     |> push_session_url()}
  end

  def handle_event("set_provider", %{"value" => provider}, socket) do
    model = default_model(provider)
    send(self(), {:load_models, provider})

    {:noreply,
     assign(socket,
       provider: provider,
       model: model,
       model_query: "",
       model_open: false,
       available_models: [],
       models_loading: true,
       queue_slots: current_queue_slots(provider),
       # The resume id belongs to the previous provider's conversation.
       provider_session_id: nil
     )}
  end

  def handle_event("focus_agent", %{"id" => id}, socket) do
    {:noreply, assign(socket, overview_focus: id)}
  end

  def handle_event("unfocus_agent", _params, socket) do
    {:noreply, assign(socket, overview_focus: nil)}
  end

  def handle_event("ov_toggle", %{"key" => key}, socket) do
    {:noreply, assign(socket, ov_expanded: toggle_member(socket.assigns.ov_expanded, key))}
  end

  def handle_event("chat_toggle", %{"key" => key}, socket) do
    {:noreply, assign(socket, chat_expanded: toggle_member(socket.assigns.chat_expanded, key))}
  end

  def handle_event("set_queue_slots", %{"value" => value}, socket) do
    case Integer.parse(value) do
      {n, _} when n > 0 ->
        provider_atom = safe_atom(socket.assigns.provider, :llamacpp)
        :ok = ExAthena.Config.set_request_queue_max_depth(provider_atom, n)
        {:noreply, assign(socket, queue_slots: n)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_model", params, socket) do
    # Combobox options send "model" (phx-value-model); the free-type input's
    # phx-blur and the form's phx-submit (Enter) send "value". A blank value is
    # ignored so the current model is never wiped to "".
    {:noreply, commit_model(socket, params["model"] || params["value"])}
  end

  # Focusing the box turns it into a search field: open the list and clear the
  # query so the full (capped) model list is browsable; typing narrows it.
  def handle_event("open_models", _params, socket) do
    {:noreply, assign(socket, model_open: true, model_query: "")}
  end

  # Closing commits the typed text (not just closes) so a free-typed model name
  # — e.g. an Ollama cloud model like "glm-5.2-cloud" that isn't in the list —
  # actually takes effect. A blank query just closes, preserving the model.
  def handle_event("close_models", _params, socket) do
    {:noreply, commit_model(socket, socket.assigns.model_query)}
  end

  def handle_event("filter_models", %{"value" => query}, socket) do
    {:noreply, assign(socket, model_query: query, model_open: true)}
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
     socket
     |> assign(
       session_id: unique_id(),
       session_title: nil,
       session_created_at: DateTime.utc_now(),
       messages: [],
       pending_images: [],
       ex_messages: [],
       provider_session_id: nil,
       tool_uis: %{},
       expanded_uis: MapSet.new(),
       details_stream: [],
       pending_assistant_msg_id: nil,
       status: nil,
       error: nil
     )
     |> push_session_url()}
  end

  def handle_event("load_session", %{"id" => id}, socket) do
    case Sessions.load(id) do
      {:ok, data} ->
        if cwd = Map.get(data, :cwd, socket.assigns.cwd), do: Sessions.touch_recent(cwd)

        {:noreply,
         socket
         |> assign_session_data(data)
         |> assign(show_sessions: false)
         |> push_session_url()}

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
         socket
         |> assign(
           session_id: new_id,
           session_title: title,
           session_created_at: DateTime.utc_now(),
           messages: forked_messages,
           pending_images: [],
           ex_messages: ex_messages,
           # A fork rewinds the transcript; the provider-side session has
           # moved past that point, so it can't be resumed.
           provider_session_id: nil,
           details_stream: details_stream,
           pending_assistant_msg_id: nil,
           status: nil,
           error: nil,
           stream_text: "",
           stream_events: [],
           stream_tool_ui: %{},
           current_action: nil,
           show_sessions: false
         )
         |> push_session_url()}
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
    # Clicking a tool one-liner in the messages pane should reveal the Log tab.
    {:noreply,
     socket
     |> assign(show_details: true, details_tab: :log)
     |> push_event("focus-detail", %{tool_call_id: tool_call_id})}
  end

  def handle_event("toggle_details", _params, socket) do
    {:noreply, assign(socket, show_details: !socket.assigns.show_details)}
  end

  def handle_event("switch_details_tab", %{"tab" => tab}, socket)
      when tab in ~w(overview log git terminal) do
    tab = String.to_existing_atom(tab)

    git_diff =
      if tab == :git, do: fetch_git_diff(socket.assigns.cwd), else: socket.assigns.git_diff

    socket = assign(socket, details_tab: tab, show_details: true, git_diff: git_diff)

    socket =
      cond do
        # Opening the Terminal tab with no terminals yet spawns the first one.
        tab == :terminal and socket.assigns.terminals == [] ->
          open_terminal(socket)

        # Re-activating the tab: the panel was display:none, so re-fit xterm
        # to the (now visible) pane width.
        tab == :terminal ->
          push_event(socket, "term_fit", %{})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("term_new", _params, socket) do
    {:noreply, open_terminal(socket)}
  end

  def handle_event("term_select", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_terminal: id)}
  end

  def handle_event("term_input", %{"id" => id, "data" => data}, socket) do
    ExAthena.Terminal.Server.input(id, data)
    {:noreply, socket}
  end

  def handle_event("term_resize", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    ExAthena.Terminal.Server.resize(id, rows, cols)
    {:noreply, socket}
  end

  # The xterm hook mounted (or reconnected) — replay the captured scrollback.
  def handle_event("term_ready", %{"id" => id}, socket) do
    ExAthena.Terminal.Server.replay(id)
    {:noreply, socket}
  end

  def handle_event("term_stop", %{"id" => id}, socket) do
    {:noreply, close_terminal(socket, id)}
  end

  def handle_event("term_stop_all", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.terminals, socket, fn t, acc -> close_terminal(acc, t.id) end)

    {:noreply, socket}
  end

  def handle_event("refresh_git_diff", _params, socket) do
    {:noreply, assign(socket, git_diff: fetch_git_diff(socket.assigns.cwd))}
  end

  # ---------------------------------------------------------------------------
  # Internal messages
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_sessions, socket) do
    {:noreply, assign(socket, recent_cwds: Sessions.list_recent())}
  end

  # Raw PTY bytes from a Terminal.Server → the matching xterm hook (base64
  # so arbitrary control bytes survive JSON transport).
  def handle_info({:term_output, id, data}, socket) do
    {:noreply, push_event(socket, "term_out", %{id: id, b64: Base.encode64(data)})}
  end

  def handle_info({:term_exit, id, code}, socket) do
    socket =
      push_event(socket, "term_out", %{
        id: id,
        b64: Base.encode64("\r\n[process exited #{code}]\r\n")
      })

    terminals =
      Enum.map(socket.assigns.terminals, fn
        %{id: ^id} = t -> %{t | status: :exited}
        t -> t
      end)

    {:noreply, assign(socket, terminals: terminals)}
  end

  def handle_info({:load_models, provider}, socket) do
    pid = self()
    Task.start(fn -> send(pid, {:models_loaded, fetch_models(provider)}) end)
    {:noreply, socket}
  end

  def handle_info({:models_loaded, models}, socket) do
    # If the current model isn't one the provider reports, select the first one
    # so we never send a stale/foreign model id (e.g. an Ollama name to Claude).
    model =
      if socket.assigns.model in models or models == [],
        do: socket.assigns.model,
        else: List.first(models)

    {:noreply, assign(socket, available_models: models, models_loading: false, model: model)}
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

  # Batched orchestration snapshots (≤ ~10/s) from the run's coordinator.
  # Scoped to the current run — late updates from a previous run are dropped.
  def handle_info({:orchestrator_update, sid, snapshot}, socket) do
    if sid == socket.assigns.orchestrator_sid do
      {:noreply,
       assign(socket, orchestrator: snapshot, gpu_stats: gpu_stats(socket.assigns.provider))}
    else
      {:noreply, socket}
    end
  end

  # The `ask_user` tool paused the run and wants an answer. Surface the
  # question, log it, and re-enable the input (see the `disabled` guard on the
  # textarea). The run task stays alive, blocked in `receive`, until the user's
  # answer is routed back via `answer_question/2`.
  def handle_info({:athena_ask_user, question}, socket) do
    detail =
      new_detail(:ask_user, socket.assigns.pending_assistant_msg_id, %{
        question: question.question,
        options: Map.get(question, :options, [])
      })

    {:noreply,
     socket
     |> assign(awaiting_question: question, current_action: nil)
     |> update(:details_stream, &[detail | &1])
     |> push_event("focus-chat-input", %{})}
  end

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
      text: Sessions.final_message_text(socket.assigns.stream_text, result),
      tool_events: socket.assigns.stream_events,
      status: status,
      ex_snapshot: ex_messages
    }

    # The chat renders the details-stream items (tool calls, text segments)
    # whenever a turn has any — and ignores msg.text. An orchestrator that
    # delegates streams no prose, so its `finish` deliverable would only appear
    # as a collapsed tool row. Surface it as a final assistant-text item so the
    # answer shows in the chat.
    details_stream =
      maybe_surface_deliverable(
        socket.assigns.details_stream,
        assistant_msg_id,
        socket.assigns.stream_text,
        result
      )

    messages = socket.assigns.messages ++ [assistant_msg]
    title = socket.assigns.session_title || derive_title(messages)

    socket =
      assign(socket,
        messages: messages,
        details_stream: details_stream,
        ex_messages: ex_messages,
        # Keep the latest provider session id for `resume:`; a result without
        # one (stateless provider) must not wipe resume state.
        provider_session_id: result.session_id || socket.assigns.provider_session_id,
        tool_uis: new_tool_uis,
        streaming: false,
        streaming_task_pid: nil,
        stream_text: "",
        stream_events: [],
        stream_tool_ui: %{},
        current_action: nil,
        awaiting_question: nil,
        pending_assistant_msg_id: nil,
        status: status,
        error: nil,
        session_title: title
      )

    socket =
      if socket.assigns.show_details and socket.assigns.details_tab == :git do
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
       awaiting_question: nil,
       error: inspect(reason)
     )}
  end

  # The run process went down. If we're still streaming, no {:athena_done,...}
  # or {:athena_error,...} arrived first — the run crashed (or was killed).
  # Reset the UI so the input is usable again. A `:normal`/`:killed` exit means
  # we already handled completion (or the user hit stop), so leave state alone.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, %{assigns: %{streaming: true}} = socket)
      when reason not in [:normal, :killed] do
    {:noreply,
     assign(socket,
       streaming: false,
       streaming_task_pid: nil,
       current_action: nil,
       awaiting_question: nil,
       error: "run crashed: #{inspect(reason)}"
     )}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

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
        <div class="theme-row" id="theme-toggle" phx-hook="ThemeToggle">
          <span class="theme-icon">☀</span>
          <span class="theme-label">Light mode</span>
          <label class="theme-switch">
            <input type="checkbox" />
            <span class="theme-track"></span>
          </label>
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
          <form phx-change="set_provider">
            <select class="field-select" name="value">
              <option :for={{label, val} <- @providers} value={val} selected={@provider == val}>
                {label}
              </option>
            </select>
          </form>
        </div>

        <div class="sidebar-section">
          <label class="field-label" title="Concurrent requests this provider may serve. Local servers default to 1 — raise only after load-testing.">
            Parallel slots
          </label>
          <form phx-change="set_queue_slots">
            <input
              class="field-input"
              type="number"
              name="value"
              min="1"
              max="16"
              value={@queue_slots}
            />
          </form>
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
              <%!-- Server-filtered model search we render ourselves, so full
                    model ids show (native <datalist> clips them to the input
                    width on Firefox/Safari) and substring search works on every
                    browser. When closed, the selection is shown as button TEXT
                    (not an <input value>): LiveView preserves user-edited input
                    values and won't reliably patch `value` after a change, so a
                    server-set value would leave the box looking empty. --%>
              <div class="model-search" phx-click-away="close_models">
                <%= if @model_open do %>
                  <form phx-change="filter_models" phx-submit="set_model" autocomplete="off">
                    <input
                      class="field-input"
                      type="text"
                      name="value"
                      value={@model_query}
                      placeholder="search models…"
                      autocomplete="off"
                      phx-debounce="120"
                      phx-mounted={JS.focus()}
                    />
                  </form>
                  <% filtered = filter_models(@available_models, @model_query) %>
                  <div class="model-options">
                    <%!-- Use phx-value-model, NOT phx-value-value: a <button>
                          has a native `value` property (empty here) that takes
                          precedence over phx-value-value, so the server would
                          receive value="" and the selection would be lost.
                          onmousedown preventDefault keeps the input focused so
                          picking an option doesn't blur+re-render mid-click. --%>
                    <button
                      :for={m <- filtered}
                      type="button"
                      class={["model-option", m == @model && "model-option--selected"]}
                      onmousedown="event.preventDefault()"
                      phx-click="set_model"
                      phx-value-model={m}
                      title={m}
                    >
                      {m}
                    </button>
                    <div :if={filtered == []} class="model-option model-option--empty">
                      no match
                    </div>
                  </div>
                <% else %>
                  <button
                    type="button"
                    class="field-input model-display"
                    phx-click="open_models"
                    title={@model}
                  >
                    <span class={[
                      "model-display-text",
                      @model in [nil, ""] && "model-display-text--empty"
                    ]}>
                      {(@model not in [nil, ""] && @model) || "search models…"}
                    </span>
                    <span class="model-display-caret">▾</span>
                  </button>
                <% end %>
              </div>
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
          <form phx-change="set_mode">
            <select class="field-select" name="value">
              <option :for={{label, val} <- @modes} value={val} selected={@mode == val}>
                {label}
              </option>
            </select>
          </form>
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
      <main class={"chat-main#{if @show_details, do: "", else: " chat-main--solo"}"} id="chat-main" phx-hook="SplitResize">
        <div class="panel-toggles">
          <button
            class={"btn-panel-toggle#{if @show_details, do: " btn-panel-toggle--active", else: ""}"}
            phx-click="toggle_details"
            title={if @show_details, do: "Hide changes", else: "Show changes"}
          >▤</button>
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
            details_stream={@details_stream}
            chat_expanded={@chat_expanded}
          />

          <%= if @streaming do %>
            <.streaming_message
              details_stream={@details_stream}
              msg_id={@pending_assistant_msg_id}
              current_action={@current_action}
              chat_expanded={@chat_expanded}
            />
          <% end %>

          <%= if @error do %>
            <div class="msg-error">⚠ {@error}</div>
          <% end %>
        </div>

        <%= if @show_details do %>
          <div class="chat-divider" id="chat-divider" aria-label="Resize panes" role="separator"></div>

          <div class="details-pane">
            <div class="details-tabs">
              <button
                class={tab_class(@details_tab, :overview)}
                phx-click="switch_details_tab"
                phx-value-tab="overview"
              >Overview</button>
              <button
                class={tab_class(@details_tab, :log)}
                phx-click="switch_details_tab"
                phx-value-tab="log"
              >Log</button>
              <button
                class={tab_class(@details_tab, :git)}
                phx-click="switch_details_tab"
                phx-value-tab="git"
              >Git</button>
              <button
                class={tab_class(@details_tab, :terminal)}
                phx-click="switch_details_tab"
                phx-value-tab="terminal"
              >Terminal</button>
              <span class="details-tabs-spacer"></span>
              <%= if @details_tab == :git do %>
                <button class="details-tab-action" phx-click="refresh_git_diff" title="Refresh">↺</button>
              <% end %>
              <%= if @details_tab == :terminal do %>
                <button class="details-tab-action" phx-click="term_new" title="New terminal">+</button>
                <button
                  :if={@terminals != []}
                  class="details-tab-action"
                  phx-click="term_stop_all"
                  title="Stop all terminals"
                >⏻ all</button>
              <% end %>
            </div>

            <%= case @details_tab do %>
              <% :overview -> %>
                <div class="details-tab-body">
                  <%= if @orchestrator do %>
                    <.overview_panel
                      orchestrator={@orchestrator}
                      gpu={@gpu_stats}
                      focus={@overview_focus}
                      expanded={@ov_expanded}
                    />
                  <% else %>
                    <div class="details-empty">
                      <div class="details-empty-title">Overview</div>
                      <div class="details-empty-sub">
                        Send a message to watch the run live: agents, todos, conclusions, and GPU queue.
                      </div>
                    </div>
                  <% end %>
                </div>
              <% :git -> %>
                <div class="details-tab-body details-tab-body--git">
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
              <% :terminal -> %>
                <%!-- Body rendered by the persistent panel below (kept
                      mounted across tab switches so xterm state survives). --%>
              <% _ -> %>
                <div class="details-tab-body" id="details-pane" phx-hook="ScrollToBottom">
                  <.details_pane stream={@details_stream} max_diff_lines={@max_diff_lines} />
                </div>
            <% end %>

            <%!-- ALWAYS mounted (hidden unless the Terminal tab is active):
                  switching right-pane tabs must not destroy the xterm hooks,
                  or remounting replays the PTY's device-queries and xterm
                  re-answers them as shell commands. --%>
            <.terminal_panel
              terminals={@terminals}
              active={@active_terminal}
              visible={@details_tab == :terminal}
            />
          </div>
        <% end %>

        <div class="input-bar" id="image-input-bar" phx-hook="ImageInput">
          <%= if @awaiting_question do %>
            <div class="ask-user">
              <div class="ask-user-head">
                <span class="ask-user-icon">?</span>
                <span class="ask-user-label">ExAthena is asking</span>
              </div>
              <div class="ask-user-question">{@awaiting_question.question}</div>
              <%= if @awaiting_question.options not in [nil, []] do %>
                <div class="ask-user-options">
                  <button
                    :for={opt <- @awaiting_question.options}
                    type="button"
                    class="ask-user-option"
                    phx-click="answer_option"
                    phx-value-option={opt}
                  >{opt}</button>
                </div>
              <% end %>
            </div>
          <% end %>
          <%= if @pending_images != [] do %>
            <div class="img-preview-bar">
              <div
                :for={{img, idx} <- Enum.with_index(@pending_images)}
                class="img-preview-item"
              >
                <img
                  src={"data:#{img.media_type};base64,#{img.data}"}
                  class="img-preview-thumb"
                  alt="attached image"
                />
                <button
                  type="button"
                  class="img-preview-remove"
                  phx-click="remove_image"
                  phx-value-index={idx}
                  title="Remove image"
                >×</button>
              </div>
            </div>
          <% end %>
          <form class="input-form" phx-submit="send">
            <label
              class={"btn-attach#{if @streaming or is_nil(@cwd), do: " btn-attach--disabled", else: ""}"}
              for="image-file-input"
              title="Attach image (or paste / drop)"
            >⊕</label>
            <input type="file" id="image-file-input" accept="image/*" multiple />
            <textarea
              id="chat-input"
              class="input-textarea"
              name="text"
              placeholder={input_placeholder(@cwd, @awaiting_question)}
              disabled={(@streaming and is_nil(@awaiting_question)) or is_nil(@cwd)}
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
    </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  defp tab_class(active, tab),
    do: "details-tab" <> if(active == tab, do: " details-tab--active", else: "")

  # ── Terminal tab ───────────────────────────────────────────────────

  defp open_terminal(socket) do
    id = "term-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
    cwd = socket.assigns.cwd || System.user_home!() || "/"
    n = length(socket.assigns.terminals) + 1

    case ExAthena.Terminal.Server.start_for(id: id, owner: self(), cwd: cwd) do
      {:ok, _pid} ->
        terminals = socket.assigns.terminals ++ [%{id: id, title: "shell #{n}", status: :running}]
        assign(socket, terminals: terminals, active_terminal: id)

      {:error, _reason} ->
        socket
    end
  end

  defp close_terminal(socket, id) do
    ExAthena.Terminal.Server.stop(id)
    terminals = Enum.reject(socket.assigns.terminals, &(&1.id == id))

    active =
      if socket.assigns.active_terminal == id do
        case terminals do
          [first | _] -> first.id
          [] -> nil
        end
      else
        socket.assigns.active_terminal
      end

    assign(socket, terminals: terminals, active_terminal: active)
  end

  attr :terminals, :list, required: true
  attr :active, :string, default: nil
  attr :visible, :boolean, default: true

  defp terminal_panel(assigns) do
    ~H"""
    <div class={["details-tab-body term-panel", not @visible && "is-hidden"]}>
      <%= if @terminals == [] do %>
        <div class="details-empty">
          <div class="details-empty-title">Terminal</div>
          <div class="details-empty-sub">No terminals. Click + to open a shell.</div>
        </div>
      <% else %>
        <div class="term-subtabs">
          <button
            :for={t <- @terminals}
            class={["term-subtab", t.id == @active && "term-subtab--active"]}
            phx-click="term_select"
            phx-value-id={t.id}
          >
            <span class={["term-dot", "term-dot--#{t.status}"]}></span>
            {t.title}
            <span class="term-subtab-close" phx-click="term_stop" phx-value-id={t.id} title="Stop">×</span>
          </button>
        </div>

        <%!-- One xterm.js instance per terminal. The hook owns its DOM
              (phx-update="ignore"); inactive ones are hidden (not removed)
              so their xterm + scrollback survive tab switches. --%>
        <div class="term-screens">
          <div
            :for={t <- @terminals}
            class={["term-xterm-wrap", t.id == @active && "is-active"]}
          >
            <div
              id={"xterm-#{t.id}"}
              class="term-xterm"
              phx-hook="Terminal"
              phx-update="ignore"
              data-term-id={t.id}
            >
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp input_placeholder(nil, _), do: "Open a project folder first (+ button)"
  defp input_placeholder(_cwd, q) when not is_nil(q), do: "Type your answer… (Enter to send)"

  defp input_placeholder(_cwd, _),
    do: "Message ExAthena… (Enter to send, Shift+Enter for newline)"

  defp message(%{msg: %{role: :user}} = assigns) do
    assigns = assign(assigns, :msg_images, Map.get(assigns.msg, :images, []))

    ~H"""
    <div class="msg msg--user">
      <div class="msg-role">you</div>
      <%= if @msg_images != [] do %>
        <div class="msg-images">
          <img :for={src <- @msg_images} src={src} class="msg-image" alt="attached image" />
        </div>
      <% end %>
      <%= if @msg.text != "" do %>
        <div class="msg-body">{@msg.text}</div>
      <% end %>
    </div>
    """
  end

  defp message(%{msg: %{role: :assistant}} = assigns) do
    assigns = assign(assigns, :items, message_items(assigns.details_stream, assigns.msg.id))

    ~H"""
    <div class="msg msg--assistant">
      <div class="msg-role">
        assistant
        <button class="btn-fork" phx-click="fork_at" phx-value-msg_id={@msg.id} title="Fork conversation from here">
          ⑂ fork
        </button>
      </div>
      <%= if @items == [] do %>
        <div class="msg-body md" id={"md-#{@msg.id}"} phx-hook="MarkdownRender" data-raw={@msg.text}></div>
      <% else %>
        <.assistant_item
          :for={item <- @items}
          item={item}
          streaming={false}
          live={false}
          chat_expanded={@chat_expanded}
        />
      <% end %>
      <%= if @msg.status do %>
        <div class="msg-footer">
          iter={@msg.status.iterations} · {@msg.status.input_tokens}/{@msg.status.output_tokens} tok · ${format_cost(@msg.status.cost_usd)}
        </div>
      <% end %>
    </div>
    """
  end

  defp streaming_message(assigns) do
    items = message_items(assigns.details_stream, assigns.msg_id)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:last_idx, length(items) - 1)

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
      <.assistant_item
        :for={{item, idx} <- Enum.with_index(@items)}
        item={item}
        streaming={true}
        live={idx == @last_idx}
        chat_expanded={@chat_expanded}
      />
      <div class="msg-body" style="white-space: pre-wrap"><span class="cursor">▋</span></div>
    </div>
    """
  end

  # Reasoning content: streams in an OPEN block while it is the newest entry
  # of the in-progress turn, then auto-collapses once the model moves on.
  # Expansion afterwards is SERVER-owned (chat_expanded) — streaming
  # re-renders would strip a user-toggled native <details open>.
  defp assistant_item(%{item: {:thinking, e}} = assigns) do
    key = "think:#{e.id}"

    assigns =
      assigns
      |> assign(:e, e)
      |> assign(:key, key)
      |> assign(:open?, assigns.live or MapSet.member?(assigns.chat_expanded, key))

    ~H"""
    <div class="msg-thinking">
      <button class="msg-thinking-summary" phx-click="chat_toggle" phx-value-key={@key}>
        {if @open?, do: "▾", else: "▸"} thinking<span :if={@live} class="msg-thinking-live">…</span>
      </button>
      <div :if={@open?} class="msg-thinking-body">{@e.payload.text}</div>
    </div>
    """
  end

  # Render a single inline item of an assistant turn (text segment, tool call,
  # or subagent activity) at its actual chronological position. Streaming text
  # is shown raw (no markdown re-render churn); finalized text is markdown.
  defp assistant_item(%{item: {:text, e}, streaming: true} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="msg-body" style="white-space: pre-wrap">{@e.payload.text}</div>
    """
  end

  defp assistant_item(%{item: {:text, e}} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="msg-body md" id={"md-#{@e.id}"} phx-hook="MarkdownRender" data-raw={@e.payload.text}></div>
    """
  end

  defp assistant_item(%{item: {:tool, call, result}} = assigns) do
    assigns = assign(assigns, call: call, result: result)

    ~H"""
    <div class="tool-events tool-events--compact">
      <button
        type="button"
        class="tool-one-liner"
        phx-click="focus_detail"
        phx-value-id={@call.payload.tool_call_id}
        title="Show details on the right"
      >
        <span class="tool-arrow">→</span>
        <span class="tool-name">{@call.payload.name}</span>
        <span class="tool-args">{preview_args(@call.payload.arguments)}</span>
        <%= if @result do %>
          <span class={"tool-result-inline#{if @result.payload.is_error, do: " tool-result-inline--error", else: ""}"}>
            <span class="tool-arrow">{if @result.payload.is_error, do: "✗", else: "←"}</span>
            <span class="tool-result-content">{summarize(@result.payload.content)}</span>
          </span>
        <% end %>
      </button>
    </div>
    """
  end

  defp assistant_item(%{item: {:subagent, spawn, result}} = assigns) do
    assigns = assign(assigns, spawn: spawn, result: result)

    ~H"""
    <div class="tool-events tool-events--compact">
      <button
        type="button"
        class="tool-one-liner"
        phx-click="focus_detail"
        phx-value-id={Map.get(@spawn.payload, :id)}
        title="Show details on the right"
      >
        <span class="tool-arrow">⊕</span>
        <span class="tool-name">subagent</span>
        <span class="tool-args">{summarize(Map.get(@spawn.payload, :prompt, ""))}</span>
        <%= if @result do %>
          <span class="tool-result-inline">
            <span class="tool-arrow">←</span>
            <span class="tool-result-content">{summarize(Map.get(@result.payload, :text, ""))}</span>
          </span>
        <% end %>
      </button>
    </div>
    """
  end

  defp assistant_item(assigns), do: ~H""

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

  defp detail_entry(%{entry: %{type: :ask_user} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--ask-user" id={"detail-#{@e.id}"}>
      <div class="detail-label">? asked the user</div>
      <div class="detail-text">{@e.payload.question}</div>
    </div>
    """
  end

  defp detail_entry(%{entry: %{type: :ask_user_answer} = e} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <div class="detail-entry detail-entry--ask-user-answer" id={"detail-#{@e.id}"}>
      <div class="detail-label">↳ user answered</div>
      <div class="detail-text">{@e.payload.answer}</div>
    </div>
    """
  end

  defp detail_entry(assigns), do: ~H""

  # ---------------------------------------------------------------------------
  # Overview tab — live orchestration state
  # ---------------------------------------------------------------------------

  defp overview_panel(assigns) do
    assigns =
      assigns
      |> assign(:focused, find_agent(assigns.orchestrator, assigns.focus))
      # parent_id → [child agents], for rendering the nested agent tree.
      |> assign(:by_parent, Enum.group_by(assigns.orchestrator.agents, & &1.parent_id))

    ~H"""
    <div class="ov-panel">
      <%= if @focus do %>
        <.agent_focus info={@focused} focus_id={@focus} />
      <% else %>
        <%= if @orchestrator.main.todos == [] and @orchestrator.agents == [] do %>
          <div class="details-empty">
            <div class="details-empty-sub">No tasks yet — the agent tree will appear here.</div>
          </div>
        <% end %>

        <%!-- The whole Overview is the task → agent tree: each todo, the agents
              working on it, and the sub-agents they spawn (recursively). --%>
        <.task_node
          :for={node <- task_nodes(@orchestrator)}
          todo={node.todo}
          agents={node.agents}
          by_parent={@by_parent}
        />

        <%= if (orphans = orphan_agents(@orchestrator)) != [] do %>
          <div class="ov-focus-label ov-tree-label">other agents</div>
          <.agent_tree_node :for={agent <- orphans} agent={agent} by_parent={@by_parent} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Task tree: one collapsible node per orchestrator todo ─────────

  # Join main todos with the TOP-LEVEL worker agents linked to them (by todo
  # content — the linkage SpawnAgent records). Nested sub-agents (parent_id is
  # another worker, not :main) render under their parent in the tree, not here.
  defp task_nodes(%{main: main, agents: agents}) do
    top = Enum.filter(agents, &(&1.parent_id == :main))

    Enum.map(main.todos, fn todo ->
      %{todo: todo, agents: Enum.filter(top, &(&1.linked_todo == todo.content))}
    end)
  end

  # Top-level workers not linked to any todo get their own subtree below the
  # task list. (Nested agents are NOT orphans — they hang off their parent.)
  @doc false
  def orphan_agents(%{main: main, agents: agents}) do
    todo_contents = MapSet.new(main.todos, & &1.content)

    Enum.filter(agents, fn a ->
      a.parent_id == :main and !(a.linked_todo && MapSet.member?(todo_contents, a.linked_todo))
    end)
  end

  # One task = an orchestrator todo. Always-expanded: its content + status,
  # then the agents working on it (recursively, via agent_tree_node).
  defp task_node(assigns) do
    ~H"""
    <div class={["ov-task", "ov-task--#{@todo.status}", "ov-task--open"]}>
      <div class="ov-task-head">
        <span class="ov-todo-marker">{todo_marker(@todo.status)}</span>
        <span class="ov-task-title">{@todo.content}</span>
        <span :if={@agents != []} class={["ov-badge", "ov-badge--#{hd(Enum.reverse(@agents)).status}"]}>
          {badge_label(hd(Enum.reverse(@agents)).status)}
        </span>
      </div>

      <div class="ov-task-body">
        <div :if={@agents == []} class="ov-task-summary ov-conclusion--derived">
          not started — no worker assigned yet
        </div>
        <.agent_tree_node :for={agent <- @agents} agent={agent} by_parent={@by_parent} />
      </div>
    </div>
    """
  end

  # Recursive tree node: one agent — its name (click → full details), status,
  # and what it's doing right now — with any sub-agents IT spawned nested and
  # indented below. Deliberately minimal: no result/sub-todo detail here, that
  # lives in the click-through agent_focus view.
  defp agent_tree_node(assigns) do
    assigns = assign(assigns, :children, Map.get(assigns.by_parent, assigns.agent.id, []))

    ~H"""
    <div class="ov-task-worker">
      <div class="ov-task-worker-head">
        <button
          class="ov-task-worker-link"
          phx-click="focus_agent"
          phx-value-id={to_string(@agent.id)}
          title="Open this agent's full context"
        >
          {@agent.name || @agent.id} →
        </button>
        <span class={["ov-badge", "ov-badge--#{@agent.status}"]}>{badge_label(@agent.status)}</span>
      </div>

      <div :if={@agent.current_action} class="ov-agent-action">⚡ {@agent.current_action}</div>

      <div :if={@children != []} class="ov-agent-children">
        <.agent_tree_node :for={child <- @children} agent={child} by_parent={@by_parent} />
      </div>
    </div>
    """
  end

  # Focus view: one agent's full observable state — its own context. Looked
  # up fresh from the live snapshot every render so it keeps updating.
  defp agent_focus(%{info: nil} = assigns) do
    ~H"""
    <div class="ov-focus">
      <button class="ov-focus-back" phx-click="unfocus_agent">← all agents</button>
      <div class="details-empty">
        <div class="details-empty-sub">Agent {@focus_id} is no longer available.</div>
      </div>
    </div>
    """
  end

  defp agent_focus(assigns) do
    ~H"""
    <div class="ov-focus">
      <button class="ov-focus-back" phx-click="unfocus_agent">← all agents</button>

      <div class="ov-agent-head">
        <span class="ov-agent-name">{@info.name || @info.id}</span>
        <span class={["ov-badge", "ov-badge--#{@info.status}"]}>{badge_label(@info.status)}</span>
      </div>

      <div :if={@info.prompt_summary} class="ov-focus-text">{@info.prompt_summary}</div>
      <div :if={@info.linked_todo} class="ov-focus-text">↳ {@info.linked_todo}</div>
      <div :if={@info.current_action} class="ov-agent-action">⚡ {@info.current_action}</div>

      <%!-- Primary content: this agent's messages, rendered like the main chat. --%>
      <div :if={@info.transcript_tail != []} class="ov-transcript-body ov-transcript-body--full">
        <.ov_agent_chat tail={@info.transcript_tail} />
      </div>

      <div :if={@info.result} class="ov-focus-section">
        <div class="ov-focus-label">contribution</div>
        <div class={["ov-worker-result", @info.status == :failed && "ov-worker-result--failed"]}>
          {@info.result}
        </div>
      </div>

      <div :if={@info.todos != []} class="ov-focus-section">
        <div class="ov-focus-label">sub-tasks</div>
        <div class="ov-todos">
          <div :for={todo <- @info.todos} class={["ov-todo", "ov-todo--#{todo.status}"]}>
            <span class="ov-todo-marker">{todo_marker(todo.status)}</span>
            <span class="ov-todo-text">{todo.content}</span>
          </div>
        </div>
      </div>

      <div :if={@info.conclusions != []} class="ov-focus-section">
        <div class="ov-focus-label">conclusions ({length(@info.conclusions)})</div>
        <div class="ov-conclusions ov-conclusions--full">
          <div
            :for={c <- @info.conclusions}
            class={["ov-conclusion", c.source != :stated && "ov-conclusion--derived"]}
          >
            <span class="ov-conclusion-iter">#{c.iteration}</span>
            {c.text}
          </div>
        </div>
      </div>

      <div class="ov-agent-footer">
        iter {@info.iteration} · {@info.usage.input_tokens}/{@info.usage.output_tokens} tok
        <%= if @info.cost_usd do %>
          · ${format_cost(@info.cost_usd)}
        <% end %>
      </div>
    </div>
    """
  end

  # Chat-style rendering of an agent's transcript tail — visually mirrors
  # the main chat: purple thinking blocks, tool rows pairing call → result,
  # plain text paragraphs. Deltas are pre-coalesced by AgentInfo.
  defp ov_agent_chat(assigns) do
    assigns = assign(assigns, :blocks, transcript_blocks(assigns.tail))

    ~H"""
    <div class="ov-chat">
      <%= for block <- @blocks do %>
        <%= case block do %>
          <% {:thinking, text} -> %>
            <div class="ov-chat-thinking">{text}</div>
          <% {:tool, call, result} -> %>
            <div class="ov-chat-tool">
              <span class="ov-chat-tool-call">→ {call}</span>
              <span :if={result} class="ov-chat-tool-result">← {result}</span>
            </div>
          <% {:error, text} -> %>
            <div class="ov-chat-error">⚠ {text}</div>
          <% {_kind, text} -> %>
            <div class="ov-chat-text">{text}</div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Pair each tool call with its immediately-following result, chat-row style.
  defp transcript_blocks([{:tool_call, call}, {:tool_result, result} | rest]),
    do: [{:tool, call, result} | transcript_blocks(rest)]

  defp transcript_blocks([{:tool_call, call} | rest]),
    do: [{:tool, call, nil} | transcript_blocks(rest)]

  defp transcript_blocks([{kind, text} | rest]), do: [{kind, text} | transcript_blocks(rest)]
  defp transcript_blocks([]), do: []

  # Snapshot ids are :main (atom) or subagent id strings; phx-value always
  # arrives as a string.
  defp find_agent(%{main: main, agents: agents}, focus_id) do
    cond do
      focus_id == nil -> nil
      focus_id == "main" -> main
      true -> Enum.find(agents, &(to_string(&1.id) == focus_id))
    end
  end

  defp badge_label(:waiting_gpu), do: "waiting gpu"
  defp badge_label(status), do: to_string(status)

  defp todo_marker(:completed), do: "✓"
  defp todo_marker(:in_progress), do: "◐"
  defp todo_marker(_), do: "○"

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
    session_id = socket.assigns.session_id
    provider = socket.assigns.provider
    model = socket.assigns.model
    mode = socket.assigns.mode
    images = socket.assigns.pending_images
    provider_session_id = socket.assigns.provider_session_id

    image_data_urls =
      Enum.map(images, fn %{data: d, media_type: t} -> "data:#{t};base64,#{d}" end)

    user_msg = %{
      id: unique_id(),
      role: :user,
      text: text,
      images: image_data_urls,
      tool_events: [],
      status: nil
    }

    assistant_msg_id = unique_id()

    new_ex_msg =
      if images == [] do
        Messages.user(text)
      else
        parts =
          Enum.map(images, fn %{data: data, media_type: type} ->
            ContentPart.image(Base.decode64!(data), type)
          end)

        parts = if text != "", do: parts ++ [ContentPart.text(text)], else: parts
        Messages.user(parts)
      end

    ex_messages = socket.assigns.ex_messages ++ [new_ex_msg]

    # One orchestration blackboard per run (Overview tab). Host-started and
    # subscribed BEFORE the run begins, so no event can be missed. The
    # coordinator is observational only — a crash never affects the run.
    run_sid = "#{session_id}-run-#{assistant_msg_id}"
    {:ok, coordinator} = ExAthena.Orchestrator.Coordinator.start_for(run_sid)
    {:ok, initial_snapshot} = ExAthena.Orchestrator.Coordinator.subscribe(run_sid, self())

    # Run options as plain data — RunServer injects the pid-bound keys
    # (:on_event, :assigns ask_user, :coordinator) so they target the stable
    # per-session server, not this LiveView pid (which dies on a reconnect).
    run_opts =
      [
        provider: safe_atom(provider, :llamacpp),
        mode: safe_mode(mode),
        messages: ex_messages,
        tools: ExAthena.Tools.builtins() ++ [ExAthena.Tools.AskUser],
        permission_mode: :accept_edits,
        # Conclusion summarizer is OFF for local thinking models: exo/Qwen3.5
        # ignore `/no_think` and req_llm's OpenAI path can't forward
        # `enable_thinking: false`, so the micro-call spends its whole budget
        # inside <think> and returns a fragment the quality gate discards. The
        # quality-gated raw thinking blob is already a good conclusion.
        conclusion_summarizer: false,
        timeout_ms: 24 * 60 * 60 * 1000
      ]
      |> maybe_put_model(model)
      |> maybe_put_resume(provider_session_id)
      |> apply_base_url(provider)
      |> maybe_put_cwd(socket.assigns.cwd)
      # Confine filesystem/bash/web access to the opened project by default
      # (override with EX_ATHENA_CONFINE=0).
      |> Keyword.put(:confine, ExAthena.confine_default?())

    user_detail = new_detail(:user_text, user_msg.id, %{text: text})
    messages = socket.assigns.messages ++ [user_msg]

    socket =
      assign(socket,
        messages: messages,
        ex_messages: ex_messages,
        session_title: socket.assigns.session_title || derive_title(messages),
        pending_images: [],
        streaming: true,
        streaming_task_pid: nil,
        stream_text: "",
        stream_events: [],
        stream_tool_ui: %{},
        current_action: nil,
        pending_assistant_msg_id: assistant_msg_id,
        details_stream: [user_detail | socket.assigns.details_stream],
        orchestrator: initial_snapshot,
        orchestrator_sid: run_sid,
        overview_focus: nil,
        ov_expanded: MapSet.new(),
        gpu_stats: gpu_stats(provider),
        error: nil
      )

    # Persist the session NOW (with the user turn) so RunServer has a file to
    # durably append the answer to, and a reconnect mid-run reopens the turn.
    save_session(socket)

    # Hand the run to the stable per-session owner, subscribing this LiveView up
    # front (no early event can race the subscription). The run now outlives a
    # reconnect; a remounting LiveView re-attaches via mount.
    {:ok, _} =
      ExAthena.Web.RunServer.start_run(session_id, %{
        run_opts: run_opts,
        assistant_msg_id: assistant_msg_id,
        run_sid: run_sid,
        coordinator: coordinator,
        subscriber: self()
      })

    {:noreply, push_session_url(socket)}
  end

  # Route the user's reply back into the run task blocked inside the `ask_user`
  # tool, then clear the pending question and resume the "thinking" indicator.
  # The run continues from where it paused — no new run is started.
  defp answer_question(socket, answer) do
    q = socket.assigns.awaiting_question

    # Route through RunServer (keyed by the stable session id) so the answer
    # reaches the blocked run even after a reconnect replaced the LiveView pid.
    ExAthena.Web.RunServer.answer(socket.assigns.session_id, q.tool_call_id, answer)

    detail =
      new_detail(:ask_user_answer, socket.assigns.pending_assistant_msg_id, %{
        question: q.question,
        answer: answer
      })

    {:noreply,
     socket
     |> assign(awaiting_question: nil, current_action: "thinking…")
     |> update(:details_stream, &[detail | &1])}
  end

  # Assign a loaded session's data onto the socket. Shared by the load_session
  # event and the connected-mount restore path so both stay in lockstep.
  defp assign_session_data(socket, data) do
    tool_uis = Map.get(data, :tool_uis, %{})

    details_stream =
      case Map.get(data, :details_stream) do
        nil -> hydrate_details_stream(data.display_messages, tool_uis)
        existing -> existing
      end

    assign(socket,
      session_id: data.id,
      session_title: data.title,
      session_created_at: Map.get(data, :created_at, DateTime.utc_now()),
      cwd: Map.get(data, :cwd, socket.assigns.cwd),
      provider: data.provider,
      model: data.model,
      model_query: "",
      model_open: false,
      mode: data.mode,
      messages: data.display_messages,
      pending_images: [],
      ex_messages: data.ex_messages,
      provider_session_id: Map.get(data, :provider_session_id),
      tool_uis: tool_uis,
      expanded_uis: MapSet.new(),
      details_stream: details_stream,
      pending_assistant_msg_id: nil,
      status: nil,
      error: nil
    )
  end

  # Keep the browser URL on `/c/:session_id` so a reconnect re-mounts with the
  # active session id. No-op until the socket is connected (push_patch needs it).
  defp push_session_url(socket) do
    if connected?(socket),
      do: push_patch(socket, to: "/c/#{socket.assigns.session_id}", replace: true),
      else: socket
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
      provider_session_id: a.provider_session_id,
      tool_uis: a.tool_uis,
      details_stream: a.details_stream
    })
  end

  # ---------------------------------------------------------------------------
  # Details-stream helpers
  # ---------------------------------------------------------------------------

  # Build the chronological (oldest-first) inline items for one assistant turn
  # in the main messages pane, derived from the details_stream (newest-first).
  # Interleaves assistant text segments, tool calls (paired with their result),
  # and subagent activity in the exact order they actually occurred.
  defp message_items(details_stream, msg_id) when is_list(details_stream) do
    entries =
      details_stream
      |> Enum.filter(&(&1.message_id == msg_id))
      |> Enum.reverse()

    results =
      for %{type: :tool_result, payload: %{tool_call_id: id}} = e <- entries,
          into: %{},
          do: {id, e}

    sub_results =
      for %{type: :subagent_result, payload: %{id: id}} = e <- entries, into: %{}, do: {id, e}

    Enum.flat_map(entries, fn
      %{type: :assistant_text} = e ->
        [{:text, e}]

      %{type: :thinking} = e ->
        [{:thinking, e}]

      %{type: :tool_call} = e ->
        [{:tool, e, Map.get(results, e.payload.tool_call_id)}]

      %{type: :subagent_spawn} = e ->
        [{:subagent, e, Map.get(sub_results, Map.get(e.payload, :id))}]

      _ ->
        []
    end)
  end

  defp message_items(_, _), do: []

  @doc false
  # Surface a `finish` deliverable as a final assistant-text item so it renders
  # as the chat answer. Skipped when the same text was already streamed as prose
  # (avoids duplicating it). details_stream is newest-first, so prepending makes
  # the deliverable the last item chronologically (after the finish tool row).
  def maybe_surface_deliverable(details_stream, msg_id, stream_text, %{
        finish_reason: :submitted,
        deliverable: d
      })
      when is_binary(d) and d != "" do
    trimmed = String.trim(d)

    cond do
      trimmed == "" -> details_stream
      is_binary(stream_text) and String.contains?(stream_text, trimmed) -> details_stream
      already_streamed_text?(details_stream, msg_id, trimmed) -> details_stream
      true -> [new_detail(:assistant_text, msg_id, %{text: d}) | details_stream]
    end
  end

  def maybe_surface_deliverable(details_stream, _msg_id, _stream_text, _result),
    do: details_stream

  defp already_streamed_text?(details_stream, msg_id, trimmed) do
    Enum.any?(details_stream, fn
      %{type: :assistant_text, message_id: ^msg_id, payload: %{text: t}} when is_binary(t) ->
        String.contains?(t, trimmed)

      _ ->
        false
    end)
  end

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
    # All working-tree changes vs HEAD — including untracked (new) files —
    # via the shared ExAthena.GitDiff (same source the TUI Changes tab uses).
    case ExAthena.GitDiff.build(cwd) do
      {:ok, ""} -> []
      {:ok, diff} -> parse_git_diff(diff)
      {:error, _} -> nil
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
      %{text: text} when is_binary(text) and text != "" -> truncate(text, 60)
      _ -> "[Image]"
    end
  end

  # One call per provider: base_url/api-key resolution, the local daemons, the
  # Claude Code CLI and JSON-spec catalogs (OpenRouter et al) are all behind
  # `ExAthena.list_models/2` now, so the picker no longer needs a clause — or a
  # config lookup — per backend.
  #
  # Ollama additionally surfaces its cloud catalog (names suffixed `-cloud`):
  # listing needs no auth, running them needs `ollama signin`. It fails soft, so
  # an offline machine still shows the locally installed models.
  #
  # Fail-soft overall: the dropdown falls back to free-text entry, and an error
  # here must not take the LiveView down.
  defp fetch_models(provider) when is_binary(provider) and provider != "" do
    case safe_atom(provider, nil) do
      nil ->
        []

      provider_atom ->
        provider_atom
        |> ExAthena.list_models(include_cloud: provider_atom == :ollama)
        |> case do
          {:ok, models} -> models |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()
          {:error, _reason} -> []
        end
    end
  end

  defp fetch_models(_), do: []

  # Commit a chosen/typed model, closing the dropdown. Blank input is ignored so
  # the current model is never wiped to "".
  defp commit_model(socket, value) do
    case value |> to_string() |> String.trim() do
      "" -> assign(socket, model_open: false)
      model -> assign(socket, model: model, model_query: "", model_open: false)
    end
  end

  defp default_provider do
    Application.get_env(:ex_athena, :default_provider, :llamacpp) |> to_string()
  end

  defp default_model(provider) do
    atom = safe_atom(provider, :llamacpp)

    Application.get_env(:ex_athena, atom, [])[:model] ||
      spec_default_model(atom) ||
      "llama3.1"
  end

  defp spec_default_model(atom) do
    case ExAthena.Config.provider_spec(atom) do
      {:ok, %{default_model: m}} when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  # Case-insensitive substring filter for the model search box, capped so a
  # provider with hundreds of models (OpenRouter) never renders them all.
  @model_results_cap 60
  @doc false
  def filter_models(models, query) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    models
    |> Enum.filter(fn m -> q == "" or String.contains?(String.downcase(m), q) end)
    |> Enum.take(@model_results_cap)
  end

  defp apply_base_url(opts, "llamacpp") do
    configured = Application.get_env(:ex_athena, :llamacpp, [])[:base_url]
    Keyword.put_new(opts, :base_url, configured || "http://localhost:8080")
  end

  defp apply_base_url(opts, "ollama") do
    configured = Application.get_env(:ex_athena, :ollama, [])[:base_url]
    Keyword.put_new(opts, :base_url, configured || "http://localhost:11434")
  end

  defp apply_base_url(opts, "exo") do
    configured = Application.get_env(:ex_athena, :exo, [])[:base_url]
    Keyword.put_new(opts, :base_url, configured || "http://localhost:52415")
  end

  defp apply_base_url(opts, _), do: opts

  defp maybe_put_model(opts, m) when is_binary(m) and m != "", do: Keyword.put(opts, :model, m)
  defp maybe_put_model(opts, _), do: opts

  defp toggle_member(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  # Current request-queue slot cap for the (string) provider selection.
  defp current_queue_slots(provider) when is_binary(provider) do
    provider
    |> safe_atom(:llamacpp)
    |> ExAthena.Config.request_queue_max_depth()
  end

  # GPU gate pressure for the Overview header. Computed on coordinator
  # updates (≤ ~10/s) — never inside render.
  defp gpu_stats(provider) when is_binary(provider) do
    atom = safe_atom(provider, :llamacpp)

    %{
      provider: atom,
      depth: ExAthena.RequestQueue.depth(atom),
      max: ExAthena.Config.request_queue_max_depth(atom),
      waiting: ExAthena.RequestQueue.waiting_count(atom)
    }
  end

  # Continue the provider-side conversation (e.g. a Claude Code CLI session)
  # captured from the previous Result. Providers without server-side session
  # state never populate it, so this stays provider-agnostic.
  defp maybe_put_resume(opts, sid) when is_binary(sid) and sid != "",
    do: Keyword.put(opts, :resume, sid)

  defp maybe_put_resume(opts, _), do: opts

  defp maybe_put_cwd(opts, cwd) when is_binary(cwd), do: Keyword.put(opts, :cwd, cwd)
  defp maybe_put_cwd(opts, _), do: opts

  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    _ -> default
  end

  # Literal atoms, NOT String.to_existing_atom/1: in a dev VM modules load
  # lazily, so an atom that only lives in another module's literals (e.g.
  # :orchestrate in Mode.@builtins) may not exist yet when the first send
  # arrives — to_existing_atom then crashes the run task with :badarg.
  # Literal clauses guarantee the atoms exist as soon as ChatLive is loaded.
  defp safe_mode("react"), do: :react
  defp safe_mode("plan_and_solve"), do: :plan_and_solve
  defp safe_mode("reflexion"), do: :reflexion
  defp safe_mode("orchestrate"), do: :orchestrate
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
