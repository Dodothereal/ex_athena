defmodule Mix.Tasks.Athena.Chat do
  @shortdoc "Interactive terminal chat REPL against the ExAthena agent loop"

  @moduledoc """
  Drops you into an interactive chat session against the ExAthena agent loop.

  Defaults to the provider set in `config :ex_athena, default_provider: :ollama`
  (falls back to `:ollama` when unset). The model is read from the provider's
  config block, e.g. `config :ex_athena, :llamacpp, model: "my-model"`.

  ## Usage

      mix athena.chat
      mix athena.chat --provider llamacpp
      mix athena.chat --provider ollama --model qwen2.5-coder:14b
      mix athena.chat --mode plan_and_solve

  ## Flags

    * `--provider NAME` — `:ollama`, `:llamacpp`, `:openai`, etc. (overrides config).
    * `--model NAME`    — initial model (overrides config).
    * `--mode NAME`     — `react`, `plan_and_solve`, or `reflexion`.

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
      OptionParser.parse(argv, strict: [model: :string, mode: :string, provider: :string])

    opts =
      []
      |> maybe_put_provider(parsed[:provider])
      |> maybe_put(:model, parsed[:model])
      |> maybe_put_mode(parsed[:mode])

    Tui.start(opts)
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
end
