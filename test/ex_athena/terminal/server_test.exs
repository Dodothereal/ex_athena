defmodule ExAthena.Terminal.ServerTest do
  @moduledoc """
  One GenServer per terminal: owns an interactive shell via erlexec, streams
  output (as themed HTML) to its owner, runs commands, interrupts (SIGINT),
  and dies with its owner. Real shell — async assertions wait on output.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Terminal.Server

  setup do
    dir = Path.join(System.tmp_dir!(), "term_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # A clean, fast, deterministic shell for tests (the default sources the
  # dev's real interactive rc, which is slow/variable in CI).
  @clean_shell [~c"/bin/bash", ~c"--norc", ~c"--noprofile", ~c"-i"]

  defp start(dir) do
    id = "t-#{System.unique_integer([:positive])}"
    {:ok, pid} = Server.start_link(id: id, owner: self(), cwd: dir, shell_cmd: @clean_shell)
    {id, pid}
  end

  test "streams command output to the owner as {:term_output, id, html}", %{dir: dir} do
    {id, _pid} = start(dir)

    Server.input(id, "echo hello-from-shell\n")

    assert_receive {:term_output, ^id, html}, 5_000
    assert IO.iodata_to_binary(html) =~ "hello-from-shell"
  end

  test "runs in the given cwd", %{dir: dir} do
    {id, _pid} = start(dir)

    Server.input(id, "pwd\n")

    assert_receive {:term_output, ^id, html}, 5_000
    # macOS /tmp is a symlink to /private/tmp — match the leaf.
    assert IO.iodata_to_binary(html) =~ Path.basename(dir)
  end

  test "interrupt sends SIGINT to a running command", %{dir: dir} do
    {id, _pid} = start(dir)

    # Long sleep, then interrupt it — the shell should regain its prompt
    # and accept a follow-up command quickly.
    Server.input(id, "sleep 30\n")
    Process.sleep(300)
    Server.interrupt(id)
    Process.sleep(200)
    Server.input(id, "echo after-interrupt\n")

    assert_receive {:term_output, ^id, html}, 5_000
    assert collect_until(id, "after-interrupt", IO.iodata_to_binary(html))
  end

  test "the server dies when its owner dies (shared-fate cleanup)", %{dir: dir} do
    id = "t-#{System.unique_integer([:positive])}"

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid} = Server.start_link(id: id, owner: owner, cwd: dir, shell_cmd: @clean_shell)
    ref = Process.monitor(pid)

    send(owner, :stop)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  # Drain term_output until `needle` appears (or timeout).
  defp collect_until(_id, needle, acc) when is_binary(acc) do
    if acc =~ needle do
      true
    else
      receive do
        {:term_output, _id, html} ->
          collect_until(nil, needle, acc <> IO.iodata_to_binary(html))
      after
        5_000 -> false
      end
    end
  end
end
