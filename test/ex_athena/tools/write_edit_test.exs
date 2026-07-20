defmodule ExAthena.Tools.WriteEditTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.{Edit, Write}

  setup do
    dir = Path.join(System.tmp_dir!(), "writeedit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir)}
  end

  describe "Write" do
    test "creates a file and reports byte count", %{dir: dir, ctx: ctx} do
      assert {:ok, msg, _ui} =
               Write.execute(%{"path" => "hello.txt", "content" => "hi"}, ctx)

      assert msg =~ "wrote 2 bytes"
      assert File.read!(Path.join(dir, "hello.txt")) == "hi"
    end

    test "creates parent directories automatically", %{dir: dir, ctx: ctx} do
      assert {:ok, _, _} =
               Write.execute(%{"path" => "nested/deeply/file.txt", "content" => "x"}, ctx)

      assert File.read!(Path.join(dir, "nested/deeply/file.txt")) == "x"
    end

    test "overwrites existing files", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "over.txt")
      File.write!(path, "old")
      assert {:ok, _, _} = Write.execute(%{"path" => "over.txt", "content" => "new"}, ctx)
      assert File.read!(path) == "new"
    end

    test "missing arguments rejected", %{ctx: ctx} do
      assert {:error, :missing_path} = Write.execute(%{}, ctx)
      assert {:error, :missing_content} = Write.execute(%{"path" => "x"}, ctx)
    end

    test "emits a :diff UI payload with before=\"\" for new files",
         %{dir: dir, ctx: ctx} do
      content = "first line\nsecond line\n"

      assert {:ok, _msg, %{kind: :diff, payload: payload}} =
               Write.execute(%{"path" => "new.txt", "content" => content}, ctx)

      assert payload.path == Path.join(dir, "new.txt")
      assert payload.before == ""
      assert payload.after == content
    end

    test "emits a :diff UI payload with the prior content as `before` on overwrite",
         %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "over.txt")
      File.write!(path, "old contents")

      assert {:ok, _msg, %{kind: :diff, payload: payload}} =
               Write.execute(%{"path" => "over.txt", "content" => "new contents"}, ctx)

      assert payload.path == path
      assert payload.before == "old contents"
      assert payload.after == "new contents"
    end
  end

  describe "Edit" do
    test "replaces a unique string exactly once", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "Hello world")

      assert {:ok, msg, ui} =
               Edit.execute(
                 %{"path" => "edit.txt", "old_string" => "world", "new_string" => "there"},
                 ctx
               )

      assert msg =~ "1 replacement"
      assert File.read!(path) == "Hello there"

      assert ui.kind == :diff
      assert ui.payload.before == "Hello world"
      assert ui.payload.after == "Hello there"
      assert ui.payload.replacements == 1
    end

    test "rejects ambiguous matches unless replace_all", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "dup.txt")
      File.write!(path, "a\na\na")

      assert {:error, {:ambiguous_match, 3}} =
               Edit.execute(%{"path" => "dup.txt", "old_string" => "a", "new_string" => "b"}, ctx)

      # replace_all lifts the uniqueness constraint
      assert {:ok, _, _ui} =
               Edit.execute(
                 %{
                   "path" => "dup.txt",
                   "old_string" => "a",
                   "new_string" => "b",
                   "replace_all" => true
                 },
                 ctx
               )

      assert File.read!(path) == "b\nb\nb"
    end

    test "missing old_string errors", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "missing.txt")
      File.write!(path, "content")

      assert {:error, :old_string_not_found} =
               Edit.execute(
                 %{"path" => "missing.txt", "old_string" => "nope", "new_string" => "new"},
                 ctx
               )
    end

    test "empty old_string rejected", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "empty.txt")
      File.write!(path, "content")

      assert {:error, :empty_old_string} =
               Edit.execute(
                 %{"path" => "empty.txt", "old_string" => "", "new_string" => "x"},
                 ctx
               )
    end
  end

  describe "confined — symlink escape" do
    setup %{dir: dir} do
      root = Path.join(dir, "root")
      outside = Path.join(dir, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "top secret")
      %{root: root, outside: outside, ctx: ToolContext.new(cwd: root, allowed_roots: [root])}
    end

    test "Write refuses a symlink pointing outside and leaves the target untouched",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      assert {:error, {:path_outside_roots, _}} =
               Write.execute(%{"path" => "leak", "content" => "pwned"}, ctx)

      assert File.read!(Path.join(outside, "secret.txt")) == "top secret"
    end

    test "Write refuses creating a file through an escaping directory symlink",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(outside, Path.join(root, "esc_dir"))

      assert {:error, {:path_outside_roots, _}} =
               Write.execute(%{"path" => "esc_dir/new.txt", "content" => "pwned"}, ctx)

      refute File.exists?(Path.join(outside, "new.txt"))
    end

    test "Write still works through an in-root directory symlink",
         %{root: root, ctx: ctx} do
      File.mkdir_p!(Path.join(root, "subdir"))
      File.ln_s!(Path.join(root, "subdir"), Path.join(root, "sublink"))

      assert {:ok, _, _} =
               Write.execute(%{"path" => "sublink/new.txt", "content" => "ok"}, ctx)

      assert File.read!(Path.join(root, "subdir/new.txt")) == "ok"
    end

    test "Edit refuses a symlink pointing outside and leaves the target untouched",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      assert {:error, {:path_outside_roots, _}} =
               Edit.execute(
                 %{"path" => "leak", "old_string" => "top", "new_string" => "pwned"},
                 ctx
               )

      assert File.read!(Path.join(outside, "secret.txt")) == "top secret"
    end
  end
end
