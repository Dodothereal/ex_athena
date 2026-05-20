defmodule ExAthena.Chat.Repl do
  @moduledoc """
  Interactive REPL driver for `mix athena.chat`.

  Reads input lines from stdin, dispatches slash commands, and routes
  free-form prompts through `ExAthena.run/2` while streaming tokens, tool
  calls, and tool results to the terminal via `ExAthena.Chat.Renderer`.

  Each turn ends with a single-line dim status footer (model · mode · iter
  · tokens · cost) — so the most recent stats are always the last line
  before the next prompt.

  Thin glue around the pure modules; manual smoke-test only.
  """

  alias ExAthena.Chat.{Commands, Ollama, Renderer, Session}
  alias ExAthena.Messages.ToolResult
  alias ExAthena.Tools

  @modes [:react, :plan_and_solve, :reflexion]

  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    # Silence routine adapter chatter (`[info] [ExAthena.ReqLLM] →stream …`,
    # `←done …`, debug text_delta breadcrumbs) so the chat shows just the
    # prompt, response, and per-turn status line. `:warning` keeps real
    # errors like `←error …` visible.
    prior_log_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      session = opts |> Session.new() |> reconcile_model_with_ollama()
      print_banner(session)

      loop(session)
    after
      Logger.configure(level: prior_log_level)
    end
  end

  defp reconcile_model_with_ollama(session) do
    case select_initial_model(session.model, Ollama.list_models([])) do
      {:ok, _} ->
        session

      {:fallback, model} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "note: configured model #{inspect(session.model)} is not installed in Ollama; using #{inspect(model)} instead.",
            :yellow
          )
        )

        Session.set_model(session, model)

      {:error, :no_models} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "warning: Ollama has no installed models. Pull one with `ollama pull <name>`, then `/model`.",
            :yellow
          )
        )

        session

      {:error, :ollama_unreachable} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "warning: Ollama is not running at the configured base_url. Start it with `ollama serve`.",
            :yellow
          )
        )

        session

      {:error, reason} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "warning: could not verify model against Ollama: #{inspect(reason)}",
            :yellow
          )
        )

        session
    end
  end

  @doc """
  Reconcile a desired Ollama model against the installed list.

  Returns:

    * `{:ok, model}` — the desired model is installed; use it as-is.
    * `{:fallback, model}` — desired model is missing; the caller should
      switch to this model (the first installed one).
    * `{:error, reason}` — the installed list could not be determined or is
      empty; the caller decides how to surface this to the user.
  """
  @spec select_initial_model(String.t(), {:ok, [String.t()]} | {:error, term()}) ::
          {:ok, String.t()}
          | {:fallback, String.t()}
          | {:error, :no_models | :ollama_unreachable | term()}
  def select_initial_model(_desired, {:ok, []}), do: {:error, :no_models}

  def select_initial_model(desired, {:ok, [_ | _] = installed}) do
    if desired in installed, do: {:ok, desired}, else: {:fallback, hd(installed)}
  end

  def select_initial_model(_desired, {:error, reason}), do: {:error, reason}

  defp loop(session) do
    input = read_prompt(session)

    case Commands.parse(input) do
      :exit ->
        Owl.IO.puts(Owl.Data.tag("Goodbye.", :light_black))
        :ok

      :noop ->
        loop(session)

      {:message, text} ->
        session
        |> handle_message(text)
        |> loop()

      {:command, verb, args} ->
        session
        |> handle_command(verb, args)
        |> loop()

      {:unknown, verb} ->
        Owl.IO.puts(Owl.Data.tag("Unknown command: /#{verb}. Try /help.", :yellow))
        loop(session)
    end
  end

  defp handle_message(session, text) do
    session = Session.append_user(session, text)
    show_thinking(session.model)

    callback = build_event_callback(session.model)
    run_opts = build_run_opts(session, callback)

    case ExAthena.run(nil, run_opts) do
      {:ok, result} ->
        # If no visible event ever fired (e.g. an immediate empty :done),
        # we still need to drop the placeholder before rendering the footer.
        clear_thinking_if_pending(session.model)
        new_session = Session.apply_result(session, result)
        print_status(new_session)
        new_session

      {:error, reason} ->
        clear_thinking_if_pending(session.model)
        Owl.IO.puts(Owl.Data.tag("\nrun error: #{inspect(reason)}", :red))
        session
    end
  end

  @thinking_flag :athena_thinking

  defp show_thinking(model) do
    IO.write([
      Owl.Data.to_chardata(Renderer.assistant_prefix(model)),
      Owl.Data.to_chardata(Owl.Data.tag("thinking…", :light_black))
    ])

    Process.put(@thinking_flag, true)
  end

  defp clear_thinking_if_pending(model) do
    if Process.get(@thinking_flag) do
      # \r returns cursor to start of line; \e[K clears to end of line;
      # then we reprint the assistant prefix so the model's response starts
      # right after it.
      IO.write([
        "\r",
        IO.ANSI.clear_line(),
        Owl.Data.to_chardata(Renderer.assistant_prefix(model))
      ])

      Process.delete(@thinking_flag)
    end
  end

  @doc """
  Build the keyword opts passed to `ExAthena.run/2` for one chat turn.

  When the host application has no `config :ex_athena, :ollama, base_url: ...`
  set, the underlying req_llm adapter falls back to `api.openai.com`. The REPL
  is Ollama-specific, so default `base_url` to `http://localhost:11434` —
  but only when the user hasn't configured one (their config wins via
  `ExAthena.Config.provider_opts/2`).
  """
  @spec build_run_opts(Session.t(), (ExAthena.Loop.Events.t() -> term())) :: keyword()
  def build_run_opts(%Session{} = session, callback) when is_function(callback, 1) do
    base = [
      provider: session.provider,
      model: session.model,
      mode: session.mode,
      tools: session.tools,
      messages: session.messages,
      permission_mode: session.permission_mode,
      on_event: callback,
      # Local Ollama models can spend minutes thinking before the first
      # chunk arrives; the default 60s request timeout fires mid-thought
      # and aborts a healthy stream. The chat REPL is interactive — the
      # user can Ctrl-C if something truly hangs — so we disable the
      # request-level timeout entirely. Stream cleanup (HTTP connection
      # close, server cancel) still runs via Stream.resource's after hook
      # if the user aborts.
      timeout_ms: :infinity
    ]

    case Application.get_env(:ex_athena, :ollama, [])[:base_url] do
      nil -> Keyword.put(base, :base_url, "http://localhost:11434")
      _configured -> base
    end
  end

  defp build_event_callback(model) do
    fn event ->
      if Renderer.visible?(event), do: clear_thinking_if_pending(model)
      Renderer.render_event(event)
    end
  end

  defp handle_command(session, :help, _) do
    Owl.IO.puts(Commands.help_text())
    session
  end

  defp handle_command(session, :clear, _) do
    cleared = Session.clear_messages(session)
    Owl.IO.puts(Owl.Data.tag("History cleared.", :light_black))
    cleared
  end

  defp handle_command(session, :expand, args) do
    results = Session.tool_results(session)
    total = length(results)
    n = parse_expand_index(args)

    case Enum.at(results, n - 1) do
      nil ->
        Owl.IO.puts(
          Owl.Data.tag(
            "No tool result at position #{n} (total: #{total}).",
            :yellow
          )
        )

      %ToolResult{} = result ->
        print_expanded(n, total, result)
    end

    session
  end

  defp handle_command(session, :tools, _) do
    Owl.IO.puts(Owl.Data.tag("Tools available:", :light_black))

    Tools.builtins()
    |> Enum.each(fn mod ->
      Owl.IO.puts("  - " <> inspect(mod))
    end)

    session
  end

  defp handle_command(session, :mode, [arg | _]) do
    case parse_mode_atom(arg) do
      {:ok, mode} ->
        new = Session.set_mode(session, mode)
        Owl.IO.puts(Owl.Data.tag("Mode → #{inspect(mode)}", :light_black))
        new

      :error ->
        Owl.IO.puts(Owl.Data.tag("Unknown mode: #{arg}. Try /mode with no args.", :yellow))
        session
    end
  end

  defp handle_command(session, :mode, []) do
    case Owl.IO.select(@modes, render_as: &inspect/1, label: "Pick a runner mode:") do
      nil ->
        session

      mode ->
        new = Session.set_mode(session, mode)
        Owl.IO.puts(Owl.Data.tag("Mode → #{inspect(mode)}", :light_black))
        new
    end
  end

  defp handle_command(session, :model, [arg | _]) when is_binary(arg) do
    new = Session.set_model(session, arg)
    Owl.IO.puts(Owl.Data.tag("Model → #{arg}", :light_black))
    new
  end

  defp handle_command(session, :model, []) do
    case Ollama.list_models([]) do
      {:ok, []} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "No models installed. Pull one with: ollama pull llama3.1",
            :yellow
          )
        )

        session

      {:ok, models} ->
        case Owl.IO.select(models, label: "Pick a model:") do
          nil ->
            session

          chosen ->
            new = Session.set_model(session, chosen)
            Owl.IO.puts(Owl.Data.tag("Model → #{chosen}", :light_black))
            new
        end

      {:error, :ollama_unreachable} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "Ollama not running. Start it with: ollama serve",
            :red
          )
        )

        session

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Could not list models: #{inspect(reason)}", :red))
        session
    end
  end

  defp parse_mode_atom(arg) when is_binary(arg) do
    candidate = String.to_existing_atom(arg)
    if candidate in @modes, do: {:ok, candidate}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp parse_expand_index([]), do: 1

  defp parse_expand_index([arg | _]) when is_binary(arg) do
    case Integer.parse(arg) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp print_expanded(n, total, %ToolResult{content: content, is_error: is_error}) do
    header_color = if is_error, do: :red, else: :cyan
    header = "▼ tool result #{n}/#{total}"
    footer = "▲ /expand"

    Owl.IO.puts(Owl.Data.tag(header, header_color))
    IO.puts(to_string(content))
    Owl.IO.puts(Owl.Data.tag(footer, :light_black))
  end

  defp read_prompt(session) do
    case IO.gets(Owl.Data.to_chardata(prompt_label(session))) do
      :eof -> :eof
      {:error, _} -> :eof
      line when is_binary(line) -> String.trim_trailing(line, "\n")
    end
  end

  defp prompt_label(_session) do
    Owl.Data.tag("me ▸ ", [:green, :bright])
  end

  defp print_banner(session) do
    Owl.IO.puts([
      Owl.Data.tag("ExAthena chat", :cyan),
      "  ",
      Owl.Data.tag("(/help for commands, /exit to quit)", :light_black)
    ])

    Owl.IO.puts(
      Owl.Data.tag(
        "provider=#{session.provider}  model=#{session.model}  mode=#{inspect(session.mode)}",
        :light_black
      )
    )
  end

  defp print_status(session) do
    Owl.IO.puts(
      Renderer.status_text(%{
        model: session.model,
        mode: session.mode,
        iteration: session.iteration,
        usage: session.usage,
        cost_usd: session.cost_usd
      })
    )
  end
end
