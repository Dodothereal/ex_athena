defmodule ExAthena.ToolContextTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext

  describe "resolve_path/2 — unconfined (default)" do
    setup do
      %{ctx: ToolContext.new(cwd: "/work/proj")}
    end

    test "expands a relative path against cwd", %{ctx: ctx} do
      assert {:ok, "/work/proj/lib/a.ex"} = ToolContext.resolve_path(ctx, "lib/a.ex")
    end

    test "lets absolute paths through untouched (historical behaviour)", %{ctx: ctx} do
      assert {:ok, "/etc/passwd"} = ToolContext.resolve_path(ctx, "/etc/passwd")
    end

    test "rejects relative traversal and null bytes", %{ctx: ctx} do
      assert {:error, :path_traversal_rejected} = ToolContext.resolve_path(ctx, "../../etc")
      assert {:error, :null_byte_in_path} = ToolContext.resolve_path(ctx, "a\0b")
    end
  end

  describe "resolve_path/2 — confined to allowed_roots" do
    setup do
      %{ctx: ToolContext.new(cwd: "/work/proj", allowed_roots: ["/work/proj", "/tmp/scratch"])}
    end

    test "allows relative paths that stay inside a root", %{ctx: ctx} do
      assert {:ok, "/work/proj/lib/a.ex"} = ToolContext.resolve_path(ctx, "lib/a.ex")
    end

    test "allows absolute paths inside any root", %{ctx: ctx} do
      assert {:ok, "/work/proj/x"} = ToolContext.resolve_path(ctx, "/work/proj/x")
      assert {:ok, "/tmp/scratch/y"} = ToolContext.resolve_path(ctx, "/tmp/scratch/y")
    end

    test "rejects absolute paths outside every root", %{ctx: ctx} do
      assert {:error, {:path_outside_roots, "/etc/passwd"}} =
               ToolContext.resolve_path(ctx, "/etc/passwd")
    end

    test "rejects relative traversal that escapes a root (resolved, not string-matched)",
         %{ctx: ctx} do
      assert {:error, {:path_outside_roots, "/work/secret"}} =
               ToolContext.resolve_path(ctx, "../secret")
    end

    test "does not confuse a sibling dir with a matching prefix" do
      ctx = ToolContext.new(cwd: "/work/proj", allowed_roots: ["/work/proj"])
      # /work/proj-evil shares the "/work/proj" string prefix but is a sibling.
      assert {:error, {:path_outside_roots, "/work/proj-evil/x"}} =
               ToolContext.resolve_path(ctx, "/work/proj-evil/x")
    end

    test "null bytes are still rejected", %{ctx: ctx} do
      assert {:error, :null_byte_in_path} = ToolContext.resolve_path(ctx, "lib/a\0.ex")
    end
  end

  describe "resolve_path/2 — confined, symlink canonicalization" do
    setup %{tmp_dir: tmp} do
      root = Path.join(tmp, "root")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "top secret")

      %{
        root: root,
        outside: outside,
        ctx: ToolContext.new(cwd: root, allowed_roots: [root])
      }
    end

    @tag :tmp_dir
    test "denies a symlink inside a root that points to a file outside",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      assert {:error, {:path_outside_roots, _}} = ToolContext.resolve_path(ctx, "leak")
    end

    @tag :tmp_dir
    test "allows a symlink inside a root that points to a file inside",
         %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "real.txt"), "fine")
      File.ln_s!(Path.join(root, "real.txt"), Path.join(root, "alias"))

      assert {:ok, resolved} = ToolContext.resolve_path(ctx, "alias")
      assert File.read!(resolved) == "fine"
    end

    @tag :tmp_dir
    test "denies a path through a symlinked intermediate directory escaping the root",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(outside, Path.join(root, "esc_dir"))

      assert {:error, {:path_outside_roots, _}} =
               ToolContext.resolve_path(ctx, "esc_dir/secret.txt")
    end

    @tag :tmp_dir
    test "denies creating a new file through an escaping directory symlink",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(outside, Path.join(root, "esc_dir"))

      assert {:error, {:path_outside_roots, _}} =
               ToolContext.resolve_path(ctx, "esc_dir/brand_new.txt")
    end

    @tag :tmp_dir
    test "allows creating a new file through an in-root directory symlink",
         %{root: root, ctx: ctx} do
      File.mkdir_p!(Path.join(root, "subdir"))
      File.ln_s!(Path.join(root, "subdir"), Path.join(root, "sublink"))

      assert {:ok, _} = ToolContext.resolve_path(ctx, "sublink/new_file.txt")
    end

    @tag :tmp_dir
    test "denies a symlink loop without hanging", %{root: root, ctx: ctx} do
      File.ln_s!(Path.join(root, "loop_b"), Path.join(root, "loop_a"))
      File.ln_s!(Path.join(root, "loop_a"), Path.join(root, "loop_b"))

      assert {:error, {:path_outside_roots, _}} =
               ToolContext.resolve_path(ctx, "loop_a/x.txt")
    end

    @tag :tmp_dir
    test "a root that is itself a symlink admits paths through both spellings",
         %{tmp_dir: tmp} do
      real_root = Path.join(tmp, "real_root")
      link_root = Path.join(tmp, "link_root")
      File.mkdir_p!(real_root)
      File.ln_s!(real_root, link_root)
      File.write!(Path.join(real_root, "f.txt"), "ok")

      ctx = ToolContext.new(cwd: link_root, allowed_roots: [link_root])

      # Relative path through the symlinked root (the macOS /tmp -> /private/tmp case).
      assert {:ok, _} = ToolContext.resolve_path(ctx, "f.txt")
      # Absolute path via the canonical spelling of the same root.
      assert {:ok, _} = ToolContext.resolve_path(ctx, Path.join(real_root, "f.txt"))
    end

    @tag :tmp_dir
    test "within_roots?/2 resolves symlinks before comparing",
         %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      refute ToolContext.within_roots?(Path.join(root, "leak"), [root])
      assert ToolContext.within_roots?(Path.join(root, "anything.txt"), [root])
    end
  end

  describe "confined?/1 and within_roots?/2" do
    test "confined? reflects allowed_roots presence" do
      refute ToolContext.confined?(ToolContext.new(cwd: "/w"))
      assert ToolContext.confined?(ToolContext.new(cwd: "/w", allowed_roots: ["/w"]))
    end

    test "within_roots? matches on segments, root itself counts as inside" do
      assert ToolContext.within_roots?("/w/proj", ["/w/proj"])
      assert ToolContext.within_roots?("/w/proj/a/b", ["/w/proj"])
      refute ToolContext.within_roots?("/w/projector", ["/w/proj"])
      refute ToolContext.within_roots?("/etc", ["/w/proj"])
    end
  end
end
