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
    "help" => :help,
    "?" => :help
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
