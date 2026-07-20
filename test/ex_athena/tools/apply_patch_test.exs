defmodule ExAthena.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.ApplyPatch

  setup do
    dir = Path.join(System.tmp_dir!(), "applypatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir)}
  end

  describe "single-file single-hunk apply" do
    test "applies cleanly and reports hunks", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "test.txt"), "line1\nline2\nline3\n")

      patch = """
      --- a/test.txt
      +++ b/test.txt
      @@ -1,3 +1,3 @@
       line1
      -line2
      +line2_new
       line3
      """

      assert {:ok, msg, ui} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert msg =~ "1 hunk"
      assert File.read!(Path.join(dir, "test.txt")) == "line1\nline2_new\nline3\n"
      assert [%{hunks_applied: 1, hunks_skipped: 0}] = ui.payload.files
      assert ui.kind == :patch
    end
  end

  describe "multi-file atomic apply" do
    test "applies all files and reports each", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "file_a.txt"), "aaa\nbbb\nccc\n")
      File.write!(Path.join(dir, "file_b.txt"), "ddd\neee\nfff\n")
      File.write!(Path.join(dir, "file_c.txt"), "ggg\nhhh\niii\n")

      patch = """
      --- a/file_a.txt
      +++ b/file_a.txt
      @@ -1,3 +1,3 @@
       aaa
      -bbb
      +BBB
       ccc
      --- a/file_b.txt
      +++ b/file_b.txt
      @@ -1,3 +1,3 @@
       ddd
      -eee
      +EEE
       fff
      --- a/file_c.txt
      +++ b/file_c.txt
      @@ -1,3 +1,3 @@
       ggg
      -hhh
      +HHH
       iii
      """

      assert {:ok, _msg, ui} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert length(ui.payload.files) == 3
      assert File.read!(Path.join(dir, "file_a.txt")) == "aaa\nBBB\nccc\n"
      assert File.read!(Path.join(dir, "file_b.txt")) == "ddd\nEEE\nfff\n"
      assert File.read!(Path.join(dir, "file_c.txt")) == "ggg\nHHH\niii\n"
    end
  end

  describe "multi-hunk in one file" do
    test "applies all hunks and reports count", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "multi.txt"), "one\ntwo\nthree\nfour\nfive\n")

      patch = """
      --- a/multi.txt
      +++ b/multi.txt
      @@ -1,2 +1,2 @@
       one
      -two
      +TWO
      @@ -4,2 +4,2 @@
       four
      -five
      +FIVE
      """

      assert {:ok, _msg, ui} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert [%{hunks_applied: 2}] = ui.payload.files
      assert File.read!(Path.join(dir, "multi.txt")) == "one\nTWO\nthree\nfour\nFIVE\n"
    end
  end

  describe "atomic rollback on bad context" do
    test "no file is modified when any hunk fails context check", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "r1.txt"), "aaa\n")
      File.write!(Path.join(dir, "r2.txt"), "bbb\n")
      File.write!(Path.join(dir, "r3.txt"), "ccc\n")

      patch = """
      --- a/r1.txt
      +++ b/r1.txt
      @@ -1,1 +1,1 @@
      -aaa
      +AAA
      --- a/r2.txt
      +++ b/r2.txt
      @@ -1,1 +1,1 @@
      -WRONG_CONTENT
      +BBB
      --- a/r3.txt
      +++ b/r3.txt
      @@ -1,1 +1,1 @@
      -ccc
      +CCC
      """

      assert {:error, _} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert File.read!(Path.join(dir, "r1.txt")) == "aaa\n"
      assert File.read!(Path.join(dir, "r2.txt")) == "bbb\n"
      assert File.read!(Path.join(dir, "r3.txt")) == "ccc\n"
    end
  end

  describe "dry_run" do
    test "validates without writing to disk", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "dry.txt"), "original\n")

      patch = """
      --- a/dry.txt
      +++ b/dry.txt
      @@ -1,1 +1,1 @@
      -original
      +modified
      """

      assert {:ok, _msg, _ui} = ApplyPatch.execute(%{"patch" => patch, "dry_run" => true}, ctx)
      assert File.read!(Path.join(dir, "dry.txt")) == "original\n"
    end
  end

  describe "path traversal" do
    test "diff targeting ../escape.txt is rejected", %{ctx: ctx} do
      patch = """
      --- a/../escape.txt
      +++ b/../escape.txt
      @@ -1,1 +1,1 @@
      -old
      +new
      """

      assert {:error, _} = ApplyPatch.execute(%{"patch" => patch}, ctx)
    end
  end

  describe "confined — symlink escape" do
    setup %{dir: dir} do
      root = Path.join(dir, "root")
      outside = Path.join(dir, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "top secret\n")
      %{root: root, outside: outside, ctx: ToolContext.new(cwd: root, allowed_roots: [root])}
    end

    test "patch targeting a symlink pointing outside the roots is rejected",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      patch = """
      --- a/leak
      +++ b/leak
      @@ -1,1 +1,1 @@
      -top secret
      +pwned
      """

      assert {:error, {:path_outside_roots, _}} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert File.read!(Path.join(outside, "secret.txt")) == "top secret\n"
    end

    test "patch through an in-root symlink still applies", %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "real.txt"), "top secret\n")
      File.ln_s!(Path.join(root, "real.txt"), Path.join(root, "alias"))

      patch = """
      --- a/alias
      +++ b/alias
      @@ -1,1 +1,1 @@
      -top secret
      +edited
      """

      assert {:ok, _msg, _ui} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert File.read!(Path.join(root, "real.txt")) == "edited\n"
    end
  end

  describe "malformed patch" do
    test "empty patch string returns :empty_patch", %{ctx: ctx} do
      assert {:error, :empty_patch} = ApplyPatch.execute(%{"patch" => ""}, ctx)
    end

    test "non-diff string returns error", %{ctx: ctx} do
      assert {:error, _} = ApplyPatch.execute(%{"patch" => "this is not a diff at all"}, ctx)
    end

    test "missing patch key returns :missing_patch", %{ctx: ctx} do
      assert {:error, :missing_patch} = ApplyPatch.execute(%{}, ctx)
    end
  end

  describe "git backend" do
    test "applies via git apply inside a git repo", %{dir: dir} do
      {_, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@t.com"], cd: dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)

      ctx = ToolContext.new(cwd: dir)
      File.write!(Path.join(dir, "git_file.txt"), "hello\nworld\n")

      patch = """
      --- a/git_file.txt
      +++ b/git_file.txt
      @@ -1,2 +1,2 @@
      -hello
      +HELLO
       world
      """

      assert {:ok, _msg, _ui} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert File.read!(Path.join(dir, "git_file.txt")) == "HELLO\nworld\n"
    end

    test "bad context fails via git apply", %{dir: dir} do
      {_, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@t.com"], cd: dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)

      ctx = ToolContext.new(cwd: dir)
      File.write!(Path.join(dir, "git_bad.txt"), "actual_content\n")

      patch = """
      --- a/git_bad.txt
      +++ b/git_bad.txt
      @@ -1,1 +1,1 @@
      -wrong_context
      +new_content
      """

      assert {:error, {:git_apply_failed, _}} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert File.read!(Path.join(dir, "git_bad.txt")) == "actual_content\n"
    end
  end

  describe "non-git cwd (Elixir backend)" do
    test "plain tmp dir uses Elixir backend", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "plain.txt"), "content\n")

      patch = """
      --- a/plain.txt
      +++ b/plain.txt
      @@ -1,1 +1,1 @@
      -content
      +CONTENT
      """

      assert {:ok, _msg, _ui} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      assert File.read!(Path.join(dir, "plain.txt")) == "CONTENT\n"
    end
  end

  describe "snapshot integration" do
    test "records checkpoint for each touched path when session_id is set", %{dir: dir} do
      session_id = "test-session-#{System.unique_integer([:positive])}"
      ctx = ToolContext.new(cwd: dir, session_id: session_id)
      File.write!(Path.join(dir, "snap.txt"), "before\n")

      patch = """
      --- a/snap.txt
      +++ b/snap.txt
      @@ -1,1 +1,1 @@
      -before
      +after
      """

      assert {:ok, _, _} = ApplyPatch.execute(%{"patch" => patch}, ctx)
      history_dir = Path.join([dir, ".exathena", "file-history", session_id])
      assert File.exists?(history_dir)
    end
  end
end
