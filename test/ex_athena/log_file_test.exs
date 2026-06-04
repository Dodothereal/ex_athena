defmodule ExAthena.LogFileTest do
  # async: false — attaches a global :logger handler.
  use ExUnit.Case, async: false

  require Logger

  setup do
    on_exit(&ExAthena.LogFile.detach/0)
    :ok
  end

  test "attach!/1 creates the parent directory and returns the expanded path" do
    dir = Path.join(System.tmp_dir!(), "athena_log_#{System.unique_integer([:positive])}")
    path = Path.join([dir, "nested", "phoenix_output.log"])
    on_exit(fn -> File.rm_rf!(dir) end)

    assert ExAthena.LogFile.attach!(path) == Path.expand(path)
    assert File.dir?(Path.dirname(path))
  end

  test "attach!/1 routes Logger output to the file" do
    path = Path.join(System.tmp_dir!(), "athena_log_#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm_rf!(path) end)

    ExAthena.LogFile.attach!(path)
    marker = "log-file-marker-#{System.unique_integer([:positive])}"
    Logger.info(marker)
    :logger_std_h.filesync(:ex_athena_file)

    assert File.read!(path) =~ marker
  end

  test "detach/0 stops routing to the file" do
    path = Path.join(System.tmp_dir!(), "athena_log_#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm_rf!(path) end)

    ExAthena.LogFile.attach!(path)
    ExAthena.LogFile.detach()

    marker = "after-detach-#{System.unique_integer([:positive])}"
    Logger.info(marker)

    refute File.exists?(path) and File.read!(path) =~ marker
  end
end
