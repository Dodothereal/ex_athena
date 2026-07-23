defmodule Mix.Tasks.Athena.Chat do
  @shortdoc "Interactive terminal chat REPL against the ExAthena agent loop"

  @moduledoc """
  Drops you into an interactive chat session against the ExAthena agent loop.

  Defaults to the provider set in `config :ex_athena, default_provider: :ollama`
  (falls back to `:ollama` when unset). The model is read from the provider's
  config block, e.g. `config :ex_athena, :llamacpp, model: "my-model"`.

  For a full walkthrough — keybindings, mode switching, JSON provider setup,
  and screenshot tour — see the [TUI guide](guides/tui.md).

  ## Usage

      mix athena.chat
      mix athena.chat --provider llamacpp
      mix athena.chat --provider ollama --model qwen2.5-coder:14b
      mix athena.chat --mode plan_and_solve
      mix athena.chat -p ~/projects/my_app

  ## Flags

    * `--provider NAME` — `:ollama`, `:llamacpp`, `:openai`, etc. (overrides config).
    * `--model NAME`    — initial model (overrides config).
    * `--mode NAME`     — `react`, `plan_and_solve`, or `reflexion`.
    * `--path PATH` (`-p`) — working directory for tools that touch the
      filesystem. `~` is expanded. The chat process does NOT `cd` into
      this path; tools just receive it as their `cwd`.
    * `--log` — also write log output to `log/phoenix_output.log`.

  ## Provider-specific requirements

    * `:ollama`   — requires a running Ollama daemon (`ollama serve`).
    * `:llamacpp` — requires a running llama.cpp server (`llama-server --model ...`).
  """

  use Mix.Task

  alias ExAthena.Chat.Tui

  @valid_modes ~w(react plan_and_solve reflexion)a

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start", [])

    {parsed, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [model: :string, mode: :string, provider: :string, path: :string, log: :boolean],
        aliases: [p: :path]
      )

    if parsed[:log] do
      path = ExAthena.LogFile.attach!()
      Mix.shell().info("Logging to #{path}")
    end

    opts =
      []
      |> maybe_put_provider(parsed[:provider])
      |> maybe_put(:model, parsed[:model])
      |> maybe_put_mode(parsed[:mode])
      |> maybe_put_path(parsed[:path])

    # The TUI is only compiled when the optional :ex_ratatui dep is present.
    # Dispatch dynamically so this task still compiles when Tui is absent.
    if Code.ensure_loaded?(Tui) do
      apply(Tui, :start, [opts])
    else
      Mix.raise(
        "mix athena.chat requires the optional :ex_ratatui dependency. " <>
          "Add `{:ex_ratatui, \"~> 0.11\"}` to your deps and re-run."
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_provider(opts, nil), do: opts

  defp maybe_put_provider(opts, raw) when is_binary(raw) do
    try do
      Keyword.put(opts, :provider, String.to_existing_atom(raw))
    rescue
      ArgumentError ->
        Mix.shell().error("Unknown --provider #{raw}.")
        opts
    end
  end

  defp maybe_put_mode(opts, nil), do: opts

  defp maybe_put_mode(opts, raw) when is_binary(raw) do
    atom = String.to_atom(raw)

    if atom in @valid_modes do
      Keyword.put(opts, :mode, atom)
    else
      Mix.shell().error(
        "Unknown --mode #{raw}. Valid: " <> Enum.map_join(@valid_modes, ", ", &Atom.to_string/1)
      )

      opts
    end
  end

  defp maybe_put_path(opts, nil), do: opts

  defp maybe_put_path(opts, raw) when is_binary(raw) do
    expanded = Path.expand(raw)

    if File.dir?(expanded) do
      Keyword.put(opts, :cwd, expanded)
    else
      Mix.shell().error("--path #{raw} (expanded to #{expanded}) is not an existing directory.")
      opts
    end
  end
end
