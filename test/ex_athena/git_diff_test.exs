defmodule ExAthena.GitDiffTest do
  use ExUnit.Case, async: true

  alias ExAthena.GitDiff

  defp git!(args, cwd), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

  defp repo do
    dir = Path.join(System.tmp_dir!(), "gitdiff_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    git!(["init", "-q"], dir)
    git!(["config", "user.email", "t@t.t"], dir)
    git!(["config", "user.name", "t"], dir)
    dir
  end

  test "combines modified, deleted, AND untracked files vs HEAD" do
    dir = repo()
    File.write!(Path.join(dir, "tracked.txt"), "a\nb\n")
    File.write!(Path.join(dir, "todelete.txt"), "old\n")
    git!(["add", "-A"], dir)
    git!(["commit", "-qm", "init"], dir)

    # Modify, delete, and create.
    File.write!(Path.join(dir, "tracked.txt"), "a\nb\nc\n")
    File.rm!(Path.join(dir, "todelete.txt"))
    File.write!(Path.join(dir, "created.txt"), "brand new\n")

    assert {:ok, text} = GitDiff.build(dir)

    # Modified (already worked via `git diff HEAD`).
    assert text =~ "diff --git a/tracked.txt b/tracked.txt"
    assert text =~ "+c"

    # Deleted (already worked via `git diff HEAD`).
    assert text =~ "deleted file"
    assert text =~ "todelete.txt"

    # Created / untracked — the bug: must now be synthesized.
    assert text =~ "diff --git a/created.txt b/created.txt"
    assert text =~ "new file mode"
    assert text =~ "+brand new"
  end

  test "returns {:ok, \"\"} when there are no changes" do
    dir = repo()
    File.write!(Path.join(dir, "f.txt"), "x\n")
    git!(["add", "-A"], dir)
    git!(["commit", "-qm", "init"], dir)

    assert {:ok, ""} = GitDiff.build(dir)
  end

  test "reports a non-git directory" do
    dir = Path.join(System.tmp_dir!(), "notrepo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, :not_a_repo} = GitDiff.build(dir)
  end

  test "caps a huge untracked file instead of flooding the diff" do
    dir = repo()
    File.write!(Path.join(dir, "seed.txt"), "x\n")
    git!(["add", "-A"], dir)
    git!(["commit", "-qm", "init"], dir)

    big = String.duplicate("line\n", 5_000)
    File.write!(Path.join(dir, "big.txt"), big)

    assert {:ok, text} = GitDiff.build(dir)
    assert text =~ "diff --git a/big.txt b/big.txt"
    assert text =~ "more lines)"
  end
end
