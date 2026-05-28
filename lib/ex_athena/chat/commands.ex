defmodule ExAthena.Chat.Commands do
  @moduledoc """
  Pure parser + dispatcher for slash commands in the `mix athena.chat` REPL.

  `parse/1` maps a raw input line (or `:eof`) to one of:

    * `{:message, text}` — free-form user prompt for the agent loop.
    * `{:command, verb, args}` — recognized slash command (`:model`, `:mode`,
      `:tools`, `:clear`, `:help`).
    * `:exit` — user wants to leave the session (`/exit`, `/quit`, `/q`, EOF).
    * `:noop` — input was blank.
    * `{:unknown, verb}` — slash-prefixed input that didn't match a known verb.

  Parsing is case-insensitive on the verb and trims surrounding whitespace.
  Arguments after the verb are split on whitespace and preserved as strings.
  """

  @type result ::
          {:message, String.t()}
          | {:command, atom(), [String.t()]}
          | :exit
          | :noop
          | {:unknown, String.t()}

  @exit_verbs ~w(exit quit q)
  @known_verbs %{
    "model" => :model,
    "mode" => :mode,
    "tools" => :tools,
    "clear" => :clear,
    "expand" => :expand,
    "details" => :details,
    "cd" => :cd,
    "pwd" => :pwd,
    "tab" => :tab,
    "diff" => :diff,
    "timeline" => :timeline,
    "mouse" => :mouse,
    "help" => :help,
    "?" => :help,
    "provider" => :provider
  }

  @spec parse(String.t() | :eof) :: result()
  def parse(:eof), do: :exit

  def parse(input) when is_binary(input) do
    case String.trim(input) do
      "" -> :noop
      "/" <> rest -> parse_command(rest)
      message -> {:message, message}
    end
  end

  defp parse_command(rest) do
    {verb, args} =
      case String.split(rest, ~r/\s+/, parts: 2, trim: true) do
        [verb] -> {String.downcase(verb), []}
        [verb, tail] -> {String.downcase(verb), String.split(tail, ~r/\s+/, trim: true)}
        [] -> {"", []}
      end

    cond do
      verb in @exit_verbs -> :exit
      Map.has_key?(@known_verbs, verb) -> {:command, Map.fetch!(@known_verbs, verb), args}
      true -> {:unknown, verb}
    end
  end

  @doc """
  Canonical slash-prefixed verbs available for autocomplete, sorted
  alphabetically. The aliases (`?` for help, `q`/`quit` for exit, etc.)
  are intentionally excluded.
  """
  @spec verbs() :: [String.t()]
  def verbs do
    canonical = [
      "model",
      "mode",
      "tools",
      "clear",
      "expand",
      "details",
      "cd",
      "pwd",
      "tab",
      "diff",
      "timeline",
      "mouse",
      "help",
      "exit",
      "provider"
    ]

    canonical |> Enum.sort() |> Enum.map(&("/" <> &1))
  end

  @doc """
  One-line summary for each verb, keyed by the slash-prefixed name.
  Used to enrich autocomplete suggestions.
  """
  @spec descriptions() :: %{String.t() => String.t()}
  def descriptions do
    %{
      "/model" => "pick or set the model",
      "/mode" => "pick or set the runner mode",
      "/tools" => "list available tools",
      "/clear" => "wipe the conversation",
      "/expand" => "show full Nth tool result",
      "/details" => "toggle the details pane",
      "/cd" => "set the working directory",
      "/pwd" => "print the current directory",
      "/tab" => "switch the details tab (timeline ↔ changes)",
      "/diff" => "show Changes tab — `/diff side` for split, `/diff inline` for unified",
      "/timeline" => "show the Timeline tab",
      "/mouse" => "toggle mouse capture (off lets the terminal copy/paste natively)",
      "/help" => "show full usage help",
      "/exit" => "leave the chat",
      "/provider" => "pick or switch the active provider"
    }
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    ExAthena chat — full usage

    Slash commands:
      /model [name]      open the model picker, or set model directly
      /mode  [name]      open the mode picker, or set mode directly
                         (modes: react, plan_and_solve, reflexion)
      /tools             list the tools currently available to the agent
      /clear             wipe the conversation history (new session)
      /expand [N]        show the Nth-most-recent tool result in full
                         (default 1 = most recent)
      /details [on|off]  show or hide the right "details" pane
                         (no args = toggle)
      /cd PATH           set the working directory for tools
                         (`~` is expanded; the chat process does not chdir)
      /pwd               print the current working directory
      /tab               cycle the details-pane tab (Timeline ↔ Changes)
      /diff [side|inline]  switch to Changes tab; optionally set the layout
                         (`side` = side-by-side, `inline` = unified)
      /timeline          switch back to the Timeline tab
      /mouse [on|off]    toggle mouse capture (off lets your terminal copy
                         text via the usual click-drag; on enables wheel-
                         scrolling + tab clicks). Many terminals also let
                         you bypass capture by holding Option (macOS) or
                         Shift while click-dragging.
      /provider [name]   open the provider picker, or set provider directly
      /help, /?          show this help
      /exit, /quit, /q   leave the chat

    Keyboard:
      Enter              send the current message
      Shift+Enter        insert a newline in the message
      Ctrl+C             quit the chat
      ↑ / k              (in picker) move selection up
      ↓ / j              (in picker) move selection down
      Enter              (in picker) confirm selection
      Esc                (in picker) close without selecting

    Launch flags (mix athena.chat):
      --provider NAME    ollama, llamacpp, openai, claude, gemini, ...
      --model NAME       initial model (overrides config)
      --mode NAME        react | plan_and_solve | reflexion

    Anything that isn't a slash command is sent to the agent as a user
    message. Tool calls and results stream inline; use /expand N to see
    the full text of a truncated tool result.
    """
  end
end
