defmodule ExAthena.SandboxTest do
  use ExUnit.Case, async: true

  alias ExAthena.Sandbox

  describe "macos_profile/1 (SBPL)" do
    test "denies writes by default and allows them under each root plus temp/dev" do
      profile = Sandbox.macos_profile(["/work/proj", "/tmp/scratch"])

      assert profile =~ "(deny file-write*)"
      assert profile =~ ~s|(subpath "/work/proj")|
      assert profile =~ ~s|(subpath "/tmp/scratch")|
      assert profile =~ ~s|(subpath "/private/var/folders")|
      assert profile =~ ~s|(subpath "/dev")|
      # reads/exec/network remain open
      assert profile =~ "(allow default)"
    end

    test "escapes quotes in a root path" do
      profile = Sandbox.macos_profile([~s|/weird/"q|])
      assert profile =~ ~S|(subpath "/weird/\"q")|
    end
  end

  describe "bwrap_args/2" do
    test "mounts / read-only and binds each root read-write, chdir to cwd" do
      args = Sandbox.bwrap_args(["/work/proj", "/tmp/scratch"], "/work/proj")

      assert ["--ro-bind", "/", "/" | _] = args
      assert chunk?(args, ["--bind", "/work/proj", "/work/proj"])
      assert chunk?(args, ["--bind", "/tmp/scratch", "/tmp/scratch"])
      assert chunk?(args, ["--bind", "/tmp", "/tmp"])
      assert chunk?(args, ["--chdir", "/work/proj"])
      assert List.last(args) == "--"
    end
  end

  describe "wrap/3" do
    test "returns runnable argv; sh -c command is preserved either way" do
      {tag, {exe, args}} = Sandbox.wrap("echo hi", ["/work/proj"], "/work/proj")

      assert tag in [:ok, :unavailable]
      assert is_binary(exe)
      # The shell command is always the tail, regardless of wrapping.
      assert List.starts_with?(Enum.reverse(args), ["echo hi", "-c"])
    end
  end

  # True when `sub` appears as a contiguous run inside `list`.
  defp chunk?(list, sub) do
    list
    |> Enum.chunk_every(length(sub), 1, :discard)
    |> Enum.any?(&(&1 == sub))
  end
end
