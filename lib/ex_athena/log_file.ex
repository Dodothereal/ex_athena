defmodule ExAthena.LogFile do
  @moduledoc """
  Optional file logging for the `athena.web` / `athena.chat` mix tasks.

  Attaching adds an Erlang `:logger` file handler alongside the default console
  handler, so the same log output the tasks print to the terminal is also
  written to a file (handy for sharing/inspecting after the fact). Enabled via
  the tasks' `--log [PATH]` flag.
  """

  @handler_id :ex_athena_file
  @default_path "log/phoenix_output.log"

  @doc "The path used when `--log` is given without an explicit value."
  def default_path, do: @default_path

  @doc """
  Attaches a file logger handler writing to `path` (default `#{@default_path}`).

  Creates the parent directory, captures `:debug` and up (so LiveView
  `HANDLE EVENT` lines are included), and returns the expanded path. Re-attaching
  replaces any previously attached handler.
  """
  @spec attach!(String.t()) :: String.t()
  def attach!(path \\ @default_path) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))

    detach()

    :ok =
      :logger.add_handler(@handler_id, :logger_std_h, %{
        level: :debug,
        config: %{type: {:file, String.to_charlist(path)}},
        formatter: Logger.Formatter.new()
      })

    path
  end

  @doc "Removes the file logger handler if attached. Safe to call when absent."
  @spec detach() :: :ok
  def detach do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, _}} -> :ok
      _ -> :ok
    end
  end
end
