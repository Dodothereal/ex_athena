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
