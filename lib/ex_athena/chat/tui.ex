defmodule ExAthena.Chat.Tui do
  @moduledoc """
  Full-screen TUI App for `mix athena.chat`, built on `ExRatatui.App`.

  Layout (see `ExAthena.Chat.Tui.View`):

    * Header (1 row) — provider · model · mode · iter · tokens · cost.
    * Messages (flex) — scrollback rendered from `state.events`.
    * Input (3 rows) — multiline textarea bound to `state.input_ref`.
    * Footer (1 row) — keyboard hints.

  When the user types a `/model` or `/mode` command with no arg, a modal
  `Popup` overlays the messages area with a navigable list. Streaming
  tokens accumulate in `state.stream_buffer` and flush into the most
  recent assistant row every ~60 ms (`@tick_interval_ms`) so a fast
  stream doesn't redraw the whole frame per token.

  The LLM run lives in an unsupervised `Task` owned by
  `ExAthena.Chat.Tui.Runner` — see that module for the bridging
  contract. The App receives `:athena_event`, `:athena_done`, and
  `:athena_error` messages via `handle_info/2`.
  """

  use ExRatatui.App

  alias ExAthena.Chat.{Commands, LlamaCpp, Ollama, Session}
  alias ExAthena.Chat.Tui.{Runner, State, View}
  alias ExAthena.Tools
  alias ExRatatui.Event
  alias ExRatatui.Frame

  @modes [:react, :plan_and_solve, :reflexion]
  @tick_interval_ms 60
  # Rows per PgUp/PgDn press. Roughly a half-page on a typical terminal —
  # comfortable for skimming without overshooting.
  @page_step 10

  @doc """
  Start the chat App and block until the user quits.

  Mirrors `ExAthena.Chat.Repl.start/1` so the Mix task signature is unchanged.
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    suspend_beam_stdin_reader()

    {:ok, pid} = start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  # BEAM's `:user_drv_reader` polls stdin in a tight loop. When the ex_ratatui
  # NIF tries to read raw keystrokes via crossterm, they race for fd 0 and
  # roughly half the bytes get consumed by BEAM and discarded. The canonical
  # fix is to launch with `-noinput`, but we can also stop the reader at
  # runtime from the Mix task path — equivalent effect, transparent to users.
  # See https://elixirforum.com/t/61856 for the original diagnosis.
  defp suspend_beam_stdin_reader do
    case Process.whereis(:user_drv_reader) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end
  end

  # ── App callbacks ────────────────────────────────────────────────────────

  @impl true
  def mount(opts) do
    prior_log_level = Logger.level()
    Logger.configure(level: :warning)

    session = opts |> Session.new() |> reconcile_initial_session()

    input_ref = ExRatatui.textarea_new()

    state =
      session
      |> State.new()
      |> Map.put(:input_ref, input_ref)
      |> Map.put(:prior_log_level, prior_log_level)
      |> banner_events()
      |> maybe_kick_git_diff()

    schedule_tick()

    {:ok, state}
  end

  @impl true
  def render(%State{} = state, %Frame{} = frame), do: View.build_frame(state, frame)

  # ── Keyboard handling ────────────────────────────────────────────────────

  @impl true
  def handle_event(%Event.Key{kind: "press"} = key, %State{popup: nil} = state) do
    handle_key(key, state)
  end

  def handle_event(%Event.Key{kind: "press"} = key, %State{popup: _} = state) do
    handle_popup_key(key, state)
  end

  def handle_event(_event, state), do: {:noreply, state}

  defp handle_key(%Event.Key{code: "c", modifiers: mods} = key, state) do
    if "ctrl" in mods do
      {:stop, restore_logger(state)}
    else
      forward_to_textarea(key, state)
    end
  end

  # ── Autocomplete navigation (only when the popup is open) ─────────────

  defp handle_key(%Event.Key{code: "up"}, %State{autocomplete: %{}} = state) do
    {:noreply, State.move_autocomplete(state, -1)}
  end

  defp handle_key(%Event.Key{code: "down"}, %State{autocomplete: %{}} = state) do
    {:noreply, State.move_autocomplete(state, +1)}
  end

  defp handle_key(%Event.Key{code: "esc"}, %State{autocomplete: %{}} = state) do
    {:noreply, State.close_autocomplete(state)}
  end

  # Tab or Enter accepts the highlighted suggestion: replace the textarea
  # contents with the selected verb (plus a trailing space so the user can
  # immediately type arguments) and close the popup. Picking from the menu
  # should complete the command text in the input box, not fire off the
  # half-typed prefix as a chat message.
  defp handle_key(%Event.Key{code: "tab"}, %State{autocomplete: %{}} = state) do
    {:noreply, accept_autocomplete(state)}
  end

  defp handle_key(%Event.Key{code: "tab"}, state), do: {:noreply, state}

  # ── Pane scrolling ────────────────────────────────────────────────────
  # PgUp/PgDn scroll the messages pane (left). Add Shift to target the
  # details pane (right). Home jumps to the very top; End returns to
  # auto-bottom so new content follows again.

  defp handle_key(%Event.Key{code: "pageup", modifiers: mods}, state) do
    if "shift" in mods,
      do: {:noreply, State.scroll_details(state, -@page_step)},
      else: {:noreply, State.scroll_messages(state, -@page_step)}
  end

  defp handle_key(%Event.Key{code: "pagedown", modifiers: mods}, state) do
    if "shift" in mods,
      do: {:noreply, State.scroll_details(state, +@page_step)},
      else: {:noreply, State.scroll_messages(state, +@page_step)}
  end

  defp handle_key(%Event.Key{code: "home", modifiers: mods}, state) do
    if "shift" in mods,
      do: {:noreply, State.scroll_details_top(state)},
      else: {:noreply, State.scroll_messages_top(state)}
  end

  defp handle_key(%Event.Key{code: "end"}, state) do
    {:noreply, State.reset_pane_scroll(state)}
  end

  defp handle_key(%Event.Key{code: "enter", modifiers: mods}, state) do
    cond do
      match?(%{}, state.autocomplete) and State.selected_autocomplete(state) != nil ->
        # Enter while the autocomplete popup is open with a selection:
        # accept the suggestion. User can press Enter again to submit.
        {:noreply, accept_autocomplete(state)}

      "shift" in mods ->
        # Shift+Enter inserts a newline into the textarea instead of submitting.
        if state.input_ref, do: ExRatatui.textarea_handle_key(state.input_ref, "enter", [])
        {:noreply, state}

      state.loading? ->
        # Don't submit while a turn is in flight — drop the keystroke.
        {:noreply, state}

      true ->
        state |> State.close_autocomplete() |> submit_input()
    end
  end

  defp handle_key(%Event.Key{code: code} = key, state) when is_binary(code) do
    forward_to_textarea(key, state)
  end

  defp handle_key(_, state), do: {:noreply, state}

  defp accept_autocomplete(state) do
    case State.selected_autocomplete(state) do
      nil ->
        State.close_autocomplete(state)

      verb ->
        if state.input_ref do
          ExRatatui.textarea_set_value(state.input_ref, verb <> " ")
        end

        State.close_autocomplete(state)
    end
  end

  defp forward_to_textarea(%Event.Key{code: code, modifiers: mods}, state) do
    if state.input_ref do
      ExRatatui.textarea_handle_key(state.input_ref, code, mods)
    end

    # After the textarea processes the key, re-read its value and refresh
    # the autocomplete popup — opens it on `/`, filters it as the user
    # types more, closes it once whitespace appears.
    state =
      case state.input_ref do
        nil -> state
        ref -> State.update_autocomplete(state, ExRatatui.textarea_get_value(ref))
      end

    {:noreply, state}
  end

  defp handle_popup_key(%Event.Key{code: code}, state) when code in ["up", "k"] do
    {:noreply, State.move_popup_selection(state, -1)}
  end

  defp handle_popup_key(%Event.Key{code: code}, state) when code in ["down", "j"] do
    {:noreply, State.move_popup_selection(state, +1)}
  end

  defp handle_popup_key(%Event.Key{code: "esc"}, state) do
    {:noreply, State.close_popup(state)}
  end

  defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:model, _, _}} = state) do
    case State.current_popup_selection(state) do
      nil ->
        {:noreply, State.close_popup(state)}

      model when is_binary(model) ->
        state
        |> State.set_model(model)
        |> State.close_popup()
        |> State.append_event({:info, "Model → " <> model})
        |> noreply()
    end
  end

  defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:mode, _, _}} = state) do
    case State.current_popup_selection(state) do
      nil ->
        {:noreply, State.close_popup(state)}

      mode when is_atom(mode) ->
        state
        |> State.set_mode(mode)
        |> State.close_popup()
        |> State.append_event({:info, "Mode → " <> inspect(mode)})
        |> noreply()
    end
  end

  defp handle_popup_key(_, state), do: {:noreply, state}

  # ── Process messages ─────────────────────────────────────────────────────

  @impl true
  def handle_info(:tick, %State{} = state) do
    schedule_tick()
    {:noreply, State.flush_stream(state)}
  end

  def handle_info({:athena_event, event}, %State{} = state) do
    state = State.append_loop_event(state, event)

    # Kick off a fresh `git diff` whenever a tool result lands — that's
    # the point where the working tree may have changed. Bounded async,
    # never blocks the UI.
    state =
      case event do
        {:tool_result, _} -> maybe_kick_git_diff(state)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({:athena_done, result}, %State{} = state) do
    new_state =
      state
      |> State.flush_stream()
      |> State.apply_result(result)
      |> State.set_loading(false)
      |> Map.put(:run_task, nil)
      |> append_status_row()
      |> maybe_kick_git_diff()

    {:noreply, new_state}
  end

  def handle_info({:git_diff, lines}, %State{} = state) when is_list(lines) do
    {:noreply, State.set_git_diff(state, lines)}
  end

  def handle_info({:athena_error, reason}, %State{} = state) do
    new_state =
      state
      |> State.flush_stream()
      |> State.set_loading(false)
      |> Map.put(:run_task, nil)
      |> State.append_event({:error, "run error: " <> inspect(reason)})

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Submission + commands ────────────────────────────────────────────────

  defp submit_input(%State{input_ref: nil} = state), do: {:noreply, state}

  defp submit_input(%State{input_ref: ref} = state) do
    raw = ExRatatui.textarea_get_value(ref)
    ExRatatui.textarea_set_value(ref, "")

    case Commands.parse(raw) do
      :noop ->
        {:noreply, state}

      :exit ->
        {:stop, restore_logger(state)}

      {:message, text} ->
        dispatch_message(text, state)

      {:command, verb, args} ->
        dispatch_command(verb, args, state)

      {:unknown, verb} ->
        append_and_noreply(state, {:warning, "Unknown command: /#{verb}. Try /help."})
    end
  end

  defp dispatch_message(text, state) do
    state =
      state
      |> State.append_event({:user, text})
      |> State.set_loading(true)
      |> State.reset_stream_state()
      |> State.reset_pane_scroll()
      |> update_in_session(&Session.append_user(&1, text))

    task_pid = Runner.start(state.session, self())
    {:noreply, %{state | run_task: task_pid}}
  end

  defp dispatch_command(:help, _args, state) do
    # Each event row renders as one line, so split the help text and append
    # one :info row per line (otherwise only the first line is visible).
    state =
      Commands.help_text()
      |> String.trim_trailing("\n")
      |> String.split("\n")
      |> Enum.reduce(state, fn line, s -> State.append_event(s, {:info, line}) end)

    {:noreply, state}
  end

  defp dispatch_command(:clear, _args, state) do
    {:noreply, State.clear_session(state)}
  end

  defp dispatch_command(:tools, _args, state) do
    rows =
      Tools.builtins()
      |> Enum.map(fn mod -> {:info, "  - " <> inspect(mod)} end)

    state = State.append_event(state, {:info, "Tools available:"})
    state = Enum.reduce(rows, state, fn row, s -> State.append_event(s, row) end)
    {:noreply, state}
  end

  defp dispatch_command(:mode, [], state) do
    {:noreply, State.open_popup(state, {:mode, @modes})}
  end

  defp dispatch_command(:mode, [arg | _], state) do
    case parse_mode_atom(arg) do
      {:ok, mode} ->
        state
        |> State.set_mode(mode)
        |> State.append_event({:info, "Mode → " <> inspect(mode)})
        |> noreply()

      :error ->
        append_and_noreply(
          state,
          {:warning, "Unknown mode: " <> arg <> ". Try /mode with no args."}
        )
    end
  end

  defp dispatch_command(:model, [], state) do
    case list_models_for(state.session) do
      {:ok, []} ->
        append_and_noreply(state, {:warning, no_models_message(state.session.provider)})

      {:ok, models} ->
        {:noreply, State.open_popup(state, {:model, models})}

      {:error, reason} when reason in [:ollama_unreachable, :llamacpp_unreachable] ->
        append_and_noreply(state, {:error, unreachable_message(state.session.provider)})

      {:error, reason} ->
        append_and_noreply(state, {:error, "Could not list models: " <> inspect(reason)})
    end
  end

  defp dispatch_command(:model, [arg | _], state) when is_binary(arg) do
    state
    |> State.set_model(arg)
    |> State.append_event({:info, "Model → " <> arg})
    |> noreply()
  end

  defp dispatch_command(:tab, _args, state) do
    state = State.cycle_details_tab(state)
    label = state.details_tab |> Atom.to_string() |> String.capitalize()
    state = maybe_kick_git_diff(state)

    state
    |> State.append_event({:info, "details tab → " <> label})
    |> noreply()
  end

  defp dispatch_command(:diff, _args, state) do
    state
    |> State.set_details_tab(:changes)
    |> State.append_event({:info, "details tab → Changes"})
    |> maybe_kick_git_diff()
    |> noreply()
  end

  defp dispatch_command(:timeline, _args, state) do
    state
    |> State.set_details_tab(:timeline)
    |> State.append_event({:info, "details tab → Timeline"})
    |> noreply()
  end

  defp dispatch_command(:cd, [], state) do
    append_and_noreply(
      state,
      {:warning, "Usage: /cd PATH  (use /pwd to see the current directory)"}
    )
  end

  defp dispatch_command(:cd, [path_arg | _], state) do
    expanded = Path.expand(path_arg)

    cond do
      not File.exists?(expanded) ->
        append_and_noreply(state, {:warning, "Path does not exist: " <> expanded})

      not File.dir?(expanded) ->
        append_and_noreply(state, {:warning, "Not a directory: " <> expanded})

      true ->
        state
        |> update_in_session(&Session.set_cwd(&1, expanded))
        |> State.append_event({:info, "cwd → " <> expanded})
        |> maybe_kick_git_diff()
        |> noreply()
    end
  end

  defp dispatch_command(:pwd, _args, state) do
    {path, source} =
      case state.session.cwd do
        nil ->
          case File.cwd() do
            {:ok, p} -> {p, " (default, process cwd — use /cd or -p to override)"}
            _ -> {"?", " (unable to read process cwd)"}
          end

        p ->
          {p, " (set via /cd or --path)"}
      end

    append_and_noreply(state, {:info, "cwd: " <> path <> source})
  end

  defp dispatch_command(:details, args, state) do
    new_value =
      case Enum.map(args, &String.downcase/1) do
        ["on"] -> true
        ["off"] -> false
        _ -> not state.show_details
      end

    label = if new_value, do: "on", else: "off"

    state
    |> Map.put(:show_details, new_value)
    |> State.append_event({:info, "Details pane → " <> label})
    |> noreply()
  end

  defp dispatch_command(:expand, args, state) do
    results = Session.tool_results(state.session)
    total = length(results)
    n = parse_expand_index(args)

    case Enum.at(results, n - 1) do
      nil ->
        append_and_noreply(
          state,
          {:warning, "No tool result at position #{n} (total: #{total})."}
        )

      %ExAthena.Messages.ToolResult{content: content, is_error: is_error} ->
        kind = if is_error, do: :tool_result_error, else: :tool_result
        header_kind = if is_error, do: :error, else: :info

        state =
          state
          |> State.append_event({header_kind, "▼ tool result #{n}/#{total}"})
          |> append_expanded_lines(kind, to_string(content))
          |> State.append_event({:info, "▲ /expand"})

        {:noreply, state}
    end
  end

  defp dispatch_command(_, _, state), do: {:noreply, state}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp append_status_row(%State{session: session} = state) do
    State.append_event(state, {:status, View.status_line(session)})
  end

  defp banner_events(%State{session: session} = state) do
    cwd_line =
      case session.cwd do
        nil ->
          case File.cwd() do
            {:ok, path} -> "cwd=" <> path <> "  (default — use /cd or -p to change)"
            _ -> "cwd=(unknown)"
          end

        path ->
          "cwd=" <> path
      end

    state
    |> State.append_event({:info, "ExAthena chat  (/help for commands, /exit to quit)"})
    |> State.append_event(
      {:info,
       "provider=#{session.provider}  model=#{session.model}  mode=#{inspect(session.mode)}"}
    )
    |> State.append_event({:info, cwd_line})
  end

  # ── Git diff (Changes tab) ────────────────────────────────────────────

  # Spawn an unsupervised Task that shells out to `git diff HEAD` in the
  # session's cwd and sends `{:git_diff, lines}` back to this process.
  # Wrapped in try/rescue/catch per the CLAUDE.md Task.start guidance.
  # Errors / non-git directories result in an empty diff (silently).
  defp maybe_kick_git_diff(state) do
    parent = self()
    cwd = state.session.cwd || File.cwd!()

    Task.start(fn ->
      try do
        lines = fetch_git_diff(cwd)
        send(parent, {:git_diff, lines})
      rescue
        _ -> send(parent, {:git_diff, []})
      catch
        _, _ -> send(parent, {:git_diff, []})
      end
    end)

    state
  end

  # Per-file caps when synthesizing diffs for untracked files. Untracked
  # files don't show up in `git diff HEAD`, so we generate a synthetic
  # "new file" diff for each — but cap so a generated/binary blob doesn't
  # flood the pane.
  @max_untracked_lines 500
  @max_untracked_bytes 100_000

  defp fetch_git_diff(cwd) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_root, 0} ->
        tracked = run_git_diff(cwd)
        untracked = render_untracked_files(cwd)

        case {tracked, untracked} do
          {[], []} -> ["(no changes vs HEAD)", "cwd: #{cwd}"]
          _ -> tracked ++ untracked
        end

      {output, _exit} ->
        ["not a git repository (cwd: #{cwd})" | String.split(String.trim(output), "\n")]
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> ["`git` executable not found on PATH"]
        other -> ["git crashed: " <> inspect(other)]
      end

    e ->
      ["git crashed: " <> Exception.message(e)]
  end

  defp run_git_diff(cwd) do
    case System.cmd("git", ["diff", "HEAD", "--color=never"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim_trailing("\n") |> String.split("\n", trim: true)
      _ -> []
    end
  end

  # `git ls-files --others --exclude-standard` lists files not tracked
  # and not gitignored. For each, synthesize a `--- /dev/null` /
  # `+++ b/<path>` diff so new files appear in the same Changes view.
  defp render_untracked_files(cwd) do
    case System.cmd("git", ["ls-files", "--others", "--exclude-standard"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&render_untracked_file(&1, cwd))

      _ ->
        []
    end
  end

  defp render_untracked_file(rel, cwd) do
    header = [
      "diff --git a/#{rel} b/#{rel}",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/#{rel}"
    ]

    path = Path.join(cwd, rel)

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_untracked_bytes ->
        header ++ ["+(file too large to show: #{size} bytes)"]

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} ->
            if binary_content?(content) do
              header ++ ["+(binary file)"]
            else
              lines = String.split(content, "\n")
              total = length(lines)
              visible = Enum.take(lines, @max_untracked_lines)
              shown = length(visible)
              diff_lines = Enum.map(visible, &("+" <> &1))

              footer =
                if total > shown,
                  do: ["+… (#{total - shown} more lines)"],
                  else: []

              header ++ diff_lines ++ footer
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # Cheap binary heuristic: NUL byte in the first 1KB.
  defp binary_content?(""), do: false

  defp binary_content?(content) do
    head_size = min(byte_size(content), 1024)
    :binary.match(binary_part(content, 0, head_size), <<0>>) != :nomatch
  end

  defp restore_logger(%State{prior_log_level: level} = state) do
    Logger.configure(level: level)
    state
  end

  defp update_in_session(state, fun), do: %{state | session: fun.(state.session)}

  defp noreply(state), do: {:noreply, state}

  defp append_and_noreply(state, row), do: {:noreply, State.append_event(state, row)}

  defp append_expanded_lines(state, kind, text) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.reduce(state, fn line, s -> State.append_event(s, {kind, line}) end)
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

  defp list_models_for(%{provider: :llamacpp}), do: LlamaCpp.list_models([])
  defp list_models_for(_session), do: Ollama.list_models([])

  defp no_models_message(:llamacpp),
    do: "No models loaded. Start one with: llama-server --model path/to/model.gguf"

  defp no_models_message(_),
    do: "No models installed. Pull one with: ollama pull llama3.1"

  defp unreachable_message(:llamacpp),
    do: "llama.cpp server not running. Start it with: llama-server --model path/to/model.gguf"

  defp unreachable_message(_),
    do: "Ollama not running. Start it with: ollama serve"

  # Reconcile the configured model against what the local provider has
  # available; surface diagnostics as banner rows but don't block startup.
  defp reconcile_initial_session(%Session{provider: :ollama} = session) do
    case Runner.select_initial_model(session.model, Ollama.list_models([])) do
      {:ok, _} -> session
      {:fallback, model} -> Session.set_model(session, model)
      {:error, _} -> session
    end
  end

  defp reconcile_initial_session(%Session{provider: :llamacpp} = session) do
    case Runner.select_initial_model(session.model, LlamaCpp.list_models([])) do
      {:ok, _} -> session
      {:fallback, model} -> Session.set_model(session, model)
      {:error, _} -> session
    end
  end

  defp reconcile_initial_session(session), do: session
end
