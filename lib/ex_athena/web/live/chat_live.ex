defmodule ExAthena.Web.Live.ChatLive do
  use Phoenix.LiveView

  alias ExAthena.Chat.{LlamaCpp, Ollama}
  alias ExAthena.Messages

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

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    provider = default_provider()
    model = default_model(provider)

    socket =
      assign(socket,
        provider: provider,
        model: model,
        mode: "react",
        available_models: [],
        messages: [],
        streaming: false,
        stream_text: "",
        stream_events: [],
        ex_messages: [],
        status: nil,
        error: nil,
        providers: @providers,
        modes: @modes
      )

    if connected?(socket), do: send(self(), {:load_models, provider})

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # User events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    if text == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      start_agent_run(socket, text)
    end
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     assign(socket,
       messages: [],
       ex_messages: [],
       status: nil,
       error: nil,
       stream_text: "",
       stream_events: []
     )}
  end

  def handle_event("set_provider", %{"value" => provider}, socket) do
    model = default_model(provider)
    send(self(), {:load_models, provider})

    {:noreply,
     assign(socket,
       provider: provider,
       model: model,
       available_models: []
     )}
  end

  def handle_event("set_model", %{"value" => model}, socket) do
    {:noreply, assign(socket, model: model)}
  end

  def handle_event("set_mode", %{"value" => mode}, socket) do
    {:noreply, assign(socket, mode: mode)}
  end

  # ---------------------------------------------------------------------------
  # Internal messages
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:load_models, provider}, socket) do
    models = fetch_models(provider)
    {:noreply, assign(socket, available_models: models)}
  end

  def handle_info({:athena, {:content, text}}, socket) do
    {:noreply, update(socket, :stream_text, &(&1 <> text))}
  end

  def handle_info({:athena, {:tool_call, tc}}, socket) do
    event = %{type: :call, id: tc.id, name: tc.name, arguments: tc.arguments}
    {:noreply, update(socket, :stream_events, &(&1 ++ [event]))}
  end

  def handle_info({:athena, {:tool_result, tr}}, socket) do
    event = %{
      type: :result,
      tool_call_id: tr.tool_call_id,
      content: to_string(tr.content),
      is_error: tr.is_error || false
    }

    {:noreply, update(socket, :stream_events, &(&1 ++ [event]))}
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

    assistant_msg = %{
      id: unique_id(),
      role: :assistant,
      text: socket.assigns.stream_text,
      tool_events: socket.assigns.stream_events,
      status: status
    }

    ex_messages =
      case result.messages do
        [_ | _] = msgs -> msgs
        _ -> socket.assigns.ex_messages
      end

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [assistant_msg],
       ex_messages: ex_messages,
       streaming: false,
       stream_text: "",
       stream_events: [],
       status: status,
       error: nil
     )}
  end

  def handle_info({:athena_error, reason}, socket) do
    {:noreply,
     assign(socket,
       streaming: false,
       error: inspect(reason)
     )}
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="app">
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
              phx-value-value={@model}
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

        <div class="sidebar-section">
          <button class="btn-clear" phx-click="clear">Clear history</button>
        </div>

        <%= if @status do %>
          <div class="status-block">
            <div class="status-row">
              <span class="status-key">iter</span>
              <span class="status-val">{@status.iterations}</span>
            </div>
            <div class="status-row">
              <span class="status-key">in tok</span>
              <span class="status-val">{@status.input_tokens}</span>
            </div>
            <div class="status-row">
              <span class="status-key">out tok</span>
              <span class="status-val">{@status.output_tokens}</span>
            </div>
            <div class="status-row">
              <span class="status-key">cost</span>
              <span class="status-val">${format_cost(@status.cost_usd)}</span>
            </div>
          </div>
        <% end %>
      </aside>

      <main class="chat-main">
        <div class="messages" id="messages" phx-hook="ScrollToBottom">
          <%= if @messages == [] and not @streaming do %>
            <div class="empty-state">
              <div class="empty-icon">◈</div>
              <div class="empty-title">ExAthena</div>
              <div class="empty-sub">Provider-agnostic agent loop · {@provider} · {@mode}</div>
            </div>
          <% end %>

          <.message :for={msg <- @messages} msg={msg} />

          <%= if @streaming do %>
            <.streaming_message text={@stream_text} events={@stream_events} />
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
            <button class={"btn-send#{if @streaming, do: " btn-send--disabled", else: ""}"} type="submit" disabled={@streaming}>
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
      <div class="msg-role">assistant</div>
      <.tool_events events={@msg.tool_events} />
      <div class="msg-body" style="white-space: pre-wrap">{@msg.text}</div>
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
      <div class="msg-role">assistant <span class="thinking-dot">●</span></div>
      <.tool_events events={@events} />
      <div class="msg-body" style="white-space: pre-wrap">
        {@text}<span class="cursor">▋</span>
      </div>
    </div>
    """
  end

  defp tool_events(%{events: []} = assigns), do: ~H""

  defp tool_events(assigns) do
    calls =
      assigns.events
      |> Enum.filter(&(&1.type == :call))

    results_by_id =
      assigns.events
      |> Enum.filter(&(&1.type == :result))
      |> Map.new(&{&1.tool_call_id, &1})

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
          </div>
        <% end %>
      </div>
    </div>
    """
  end

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
       error: nil
     )}
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

  defp maybe_put_model(opts, model) when is_binary(model) and model != "",
    do: Keyword.put(opts, :model, model)

  defp maybe_put_model(opts, _), do: opts

  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    _ -> default
  end

  defp safe_mode(mode) when mode in ["react", "plan_and_solve", "reflexion"],
    do: String.to_existing_atom(mode)

  defp safe_mode(_), do: :react

  defp unique_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  defp format_cost(nil), do: "0.0000"
  defp format_cost(cost), do: :erlang.float_to_binary(cost / 1.0, decimals: 4)

  defp preview_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp preview_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}: #{truncate(inspect(v), 50)}" end)
    |> Enum.join(", ")
  end

  defp preview_args(other), do: inspect(other)

  defp summarize(text) do
    text = String.trim_trailing(to_string(text), "\n")
    lines = String.split(text, "\n")
    first = lines |> List.first("") |> truncate(120)
    if length(lines) > 1, do: "#{first} · #{length(lines)} lines", else: first
  end

  defp truncate(text, limit) when byte_size(text) <= limit, do: text
  defp truncate(text, limit), do: String.slice(text, 0, limit) <> "…"
end
