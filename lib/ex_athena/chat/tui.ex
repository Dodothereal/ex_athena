# The TUI requires the OPTIONAL `:ex_ratatui` dependency. Guard the whole
# module so ExAthena still compiles for consumers that don't pull ex_ratatui
# (declared `optional: true`). Without this, `use ExRatatui.App` raises
# `module ExRatatui.App is not loaded` at compile time for every such consumer.
if Code.ensure_loaded?(ExRatatui.App) do
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
    # Rows per mouse-wheel click.
    @wheel_step 3

    @doc """
    Start the chat App and block until the user quits.

    Mirrors `ExAthena.Chat.Repl.start/1` so the Mix task signature is unchanged.
    """
    @spec start(keyword()) :: :ok
    def start(opts \\ []) do
      suspend_beam_stdin_reader()

      {:ok, pid} = start_link(opts)

      # ex_ratatui's NIF enables crossterm raw mode + alternate screen but
      # does NOT toggle mouse capture, so wheel/click events never reach us.
      # Enable X10 mouse reporting + SGR-extended mode (unlimited coords)
      # ourselves via ANSI. We bypass :standard_io and write to /dev/tty
      # directly because suspend_beam_stdin_reader/0 above tears down
      # BEAM's I/O subsystem — IO.write/2 to :standard_io would raise
      # :terminated.
      write_to_tty("\e[?1000h\e[?1006h")

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          write_to_tty("\e[?1006l\e[?1000l")
          :ok
      end
    end

    defp write_to_tty(bytes) do
      case File.open("/dev/tty", [:write, :raw]) do
        {:ok, dev} ->
          try do
            IO.binwrite(dev, bytes)
          after
            File.close(dev)
          end

        _ ->
          :ok
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

    # Mouse wheel: scroll the pane under the cursor by @wheel_step rows.
    def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_up", x: x, y: y}, state) do
      {:noreply, scroll_pane_at(state, x, y, -@wheel_step)}
    end

    def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_down", x: x, y: y}, state) do
      {:noreply, scroll_pane_at(state, x, y, +@wheel_step)}
    end

    # Left-click on a details tab title → switch tabs.
    def handle_event(
          %ExRatatui.Event.Mouse{kind: "down", button: "left", x: x, y: y},
          state
        ) do
      {:noreply, maybe_click_tab(state, x, y)}
    end

    def handle_event(_event, state), do: {:noreply, state}

    # ── Mouse helpers ────────────────────────────────────────────────────

    defp scroll_pane_at(state, x, y, delta) do
      layout = Process.get(:tui_layout, %{})

      cond do
        in_rect?(layout[:messages], x, y) -> State.scroll_messages(state, delta)
        in_rect?(layout[:details], x, y) -> State.scroll_details(state, delta)
        true -> state
      end
    end

    defp maybe_click_tab(state, x, y) do
      layout = Process.get(:tui_layout, %{})

      if in_rect?(layout[:tabs], x, y) and is_list(layout[:tab_titles]) do
        tabs = State.details_tabs()
        # Approximate tab width: split available width evenly. ratatui's
        # Tabs widget aligns left and uses a divider; this is a "good
        # enough" hit-test that picks the closer tab.
        tabs_rect = layout[:tabs]
        offset = x - tabs_rect.x
        slot_width = max(div(tabs_rect.width, length(tabs)), 1)
        idx = min(div(offset, slot_width), length(tabs) - 1)
        target = Enum.at(tabs, max(idx, 0))

        State.set_details_tab(state, target)
      else
        state
      end
    end

    defp in_rect?(nil, _x, _y), do: false

    defp in_rect?(%{x: rx, y: ry, width: rw, height: rh}, x, y) do
      x >= rx and x < rx + rw and y >= ry and y < ry + rh
    end

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

    # ── History navigation (Up/Down when no popup is open) ──────────────
    # First Up snapshots the current input as `history_draft`. Subsequent
    # Up steps further back; Down walks forward and ultimately restores
    # the draft. Typing anything resets the cursor (see forward_to_textarea).
    defp handle_key(%Event.Key{code: "up"}, state) do
      current = read_textarea(state)

      case State.history_prev(state, current) do
        {state, nil} -> {:noreply, state}
        {state, text} -> {:noreply, set_textarea(state, text)}
      end
    end

    defp handle_key(%Event.Key{code: "down"}, state) do
      case State.history_next(state) do
        {state, nil} -> {:noreply, state}
        {state, text} -> {:noreply, set_textarea(state, text)}
      end
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
      # types more, closes it once whitespace appears. Also cancels any
      # in-progress history navigation (typing a fresh char means the user
      # is composing, not browsing prior messages).
      state =
        case state.input_ref do
          nil ->
            state

          ref ->
            state
            |> State.update_autocomplete(ExRatatui.textarea_get_value(ref))
            |> State.reset_history_nav()
        end

      {:noreply, state}
    end

    defp read_textarea(%State{input_ref: nil}), do: ""
    defp read_textarea(%State{input_ref: ref}), do: ExRatatui.textarea_get_value(ref) || ""

    defp set_textarea(%State{input_ref: nil} = state, _text), do: state

    defp set_textarea(%State{input_ref: ref} = state, text) do
      ExRatatui.textarea_set_value(ref, text || "")
      state
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

    defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:provider, _, _}} = state) do
      case State.current_popup_selection(state) do
        nil ->
          {:noreply, State.close_popup(state)}

        name when is_binary(name) ->
          provider_atom = provider_name_to_atom(name)

          state
          |> State.set_provider(provider_atom)
          |> State.close_popup()
          |> State.append_event({:info, "Provider → " <> name})
          |> append_provider_details(name)
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

    defp submit_input(%State{api_key_pending: true} = state) do
      raw = read_textarea(state) |> String.trim()
      if state.input_ref, do: ExRatatui.textarea_set_value(state.input_ref, "")

      cond do
        raw == "" ->
          append_and_noreply(
            state,
            {:warning, "API key cannot be empty. Enter it below (or /cancel to abort):"}
          )

        raw in ["/exit", "/quit"] ->
          {:stop, restore_logger(state)}

        raw == "/cancel" ->
          state
          |> Map.put(:api_key_pending, false)
          |> Map.put(:pending_message, nil)
          |> State.append_event({:info, "API key prompt cancelled."})
          |> noreply()

        true ->
          pending = state.pending_message

          state =
            state
            |> State.set_api_key(raw)
            |> Map.put(:pending_message, nil)
            |> State.append_event({:info, "API key saved for this session."})

          if pending, do: do_dispatch_message(pending, state), else: noreply(state)
      end
    end

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

    defp dispatch_message(text, %State{api_key_pending: false} = state) do
      case check_api_key_needed(state) do
        {:needs_key, provider_name, api_key_env} ->
          state
          |> State.append_event({:info, "Provider '#{provider_name}' requires an API key."})
          |> State.append_event({:info, "Env: #{api_key_env} (not set). Enter key below:"})
          |> Map.put(:api_key_pending, true)
          |> Map.put(:pending_message, text)
          |> noreply()

        :ok ->
          do_dispatch_message(text, state)
      end
    end

    defp do_dispatch_message(text, state) do
      state =
        state
        |> State.append_event({:user, text})
        |> State.set_loading(true)
        |> State.reset_stream_state()
        |> State.reset_pane_scroll()
        |> State.reset_history_nav()
        |> update_in_session(&Session.append_user(&1, text))

      extra_opts = if state.api_key, do: [api_key: state.api_key], else: []
      task_pid = Runner.start(state.session, self(), extra_opts)
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

    defp dispatch_command(:provider, [], state) do
      providers = ExAthena.Config.list_providers()
      items = Enum.map(providers, fn p -> {p.name, p.display_name} end)
      {:noreply, State.open_popup(state, {:provider, items})}
    end

    defp dispatch_command(:provider, [arg | _], state) when is_binary(arg) do
      provider = provider_name_to_atom(arg)

      state
      |> State.set_provider(provider)
      |> State.append_event({:info, "Provider → " <> arg})
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

    defp dispatch_command(:mouse, args, state) do
      requested =
        case args |> Enum.map(&String.downcase/1) |> List.first() do
          "on" -> true
          "off" -> false
          _ -> not state.mouse_enabled
        end

      if requested do
        # X10 click reporting + SGR (extended coords) — same sequences
        # Tui.start/1 writes on app startup.
        write_to_tty("\e[?1000h\e[?1006h")
      else
        write_to_tty("\e[?1006l\e[?1000l")
      end

      label = if requested, do: "on", else: "off (terminal text selection restored)"

      state
      |> State.set_mouse_enabled(requested)
      |> State.append_event({:info, "mouse capture → " <> label})
      |> noreply()
    end

    defp dispatch_command(:diff, args, state) do
      case args |> Enum.map(&String.downcase/1) |> List.first() do
        mode when mode in ["side", "side-by-side", "split"] ->
          state
          |> State.set_diff_mode(:side_by_side)
          |> State.set_details_tab(:changes)
          |> State.append_event({:info, "diff layout → side-by-side"})
          |> maybe_kick_git_diff()
          |> noreply()

        "inline" ->
          state
          |> State.set_diff_mode(:inline)
          |> State.set_details_tab(:changes)
          |> State.append_event({:info, "diff layout → inline"})
          |> maybe_kick_git_diff()
          |> noreply()

        _ ->
          state
          |> State.set_details_tab(:changes)
          |> State.append_event({:info, "details tab → Changes"})
          |> maybe_kick_git_diff()
          |> noreply()
      end
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
      header_base = [
        "diff --git a/#{rel} b/#{rel}",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/#{rel}"
      ]

      path = Path.join(cwd, rel)

      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} when size > @max_untracked_bytes ->
          # Synthesize a 1-line hunk header so the structured diff parser
          # counts the placeholder as part of the file rather than dropping
          # bare `+` lines that have no enclosing hunk.
          header_base ++
            ["@@ -0,0 +1,1 @@", "+(file too large to show: #{size} bytes)"]

        {:ok, %{type: :regular}} ->
          case File.read(path) do
            {:ok, content} ->
              if binary_content?(content) do
                header_base ++ ["@@ -0,0 +1,1 @@", "+(binary file)"]
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

                # `@@ -0,0 +1,N @@` — git's convention for a new file.
                hunk_header = "@@ -0,0 +1,#{shown + length(footer)} @@"
                header_base ++ [hunk_header] ++ diff_lines ++ footer
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

    defp append_provider_details(state, provider_name) do
      case lookup_provider_spec(provider_name) do
        {:ok, spec} when spec.extra_headers != %{} ->
          state
          |> State.append_detail_header("provider: #{provider_name}")
          |> State.append_detail_lines(:info, "extra_headers: #{inspect(spec.extra_headers)}")

        _ ->
          state
      end
    end

    defp lookup_provider_spec(name) when is_binary(name) do
      case Process.whereis(ExAthena.ProviderRegistry) do
        nil -> :error
        _pid -> ExAthena.ProviderRegistry.lookup(name)
      end
    end

    defp check_api_key_needed(%State{api_key: api_key, session: session}) do
      if is_nil(api_key) do
        case lookup_provider_spec(Atom.to_string(session.provider)) do
          {:ok, %{api_key_prompt: true, api_key_env: env}} when is_binary(env) ->
            if is_nil(System.get_env(env)) do
              {:needs_key, session.provider, env}
            else
              :ok
            end

          _ ->
            :ok
        end
      else
        :ok
      end
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

    defp provider_name_to_atom(name) when is_binary(name) do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> String.to_atom(name)
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

    defp list_models_for(%{provider: provider}) do
      with pid when not is_nil(pid) <- Process.whereis(ExAthena.ProviderRegistry),
           {:ok, %ExAthena.ProviderSpec{model_discovery: disc} = spec}
           when not is_nil(disc) <- ExAthena.ProviderRegistry.lookup(provider) do
        ExAthena.ModelDiscovery.list_models(spec)
      else
        _ -> Ollama.list_models([])
      end
    end

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
end
