defmodule ExAthena.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.Read

  setup do
    dir = Path.join(System.tmp_dir!(), "read_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir)}
  end

  test "reads a file and prefixes lines with numbers", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "hello.txt")
    File.write!(path, "one\ntwo\nthree")

    assert {:ok, body, ui} = Read.execute(%{"path" => "hello.txt"}, ctx)
    assert body =~ "1\tone"
    assert body =~ "2\ttwo"
    assert body =~ "3\tthree"

    assert ui.kind == :file
    assert ui.payload.path == path
    assert ui.payload.content == "one\ntwo\nthree"
  end

  test "accepts absolute paths", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "abs.txt")
    File.write!(path, "abs")
    assert {:ok, body, _ui} = Read.execute(%{"path" => path}, ctx)
    assert body =~ "abs"
  end

  test "rejects path traversal", %{ctx: ctx} do
    assert {:error, :path_traversal_rejected} =
             Read.execute(%{"path" => "../secret.txt"}, ctx)
  end

  test "rejects missing path arg", %{ctx: ctx} do
    assert {:error, :missing_path} = Read.execute(%{}, ctx)
  end

  test "rejects empty path arg (model hallucinated a read with no target)", %{ctx: ctx} do
    assert {:error, :missing_path} = Read.execute(%{"path" => ""}, ctx)
  end

  test "rejects whitespace-only path arg", %{ctx: ctx} do
    assert {:error, :missing_path} = Read.execute(%{"path" => "  \n"}, ctx)
  end

  test "surfaces File.stat errors when file is missing", %{ctx: ctx} do
    assert {:error, :enoent} = Read.execute(%{"path" => "nonexistent"}, ctx)
  end

  test "offset + limit slice", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "big.txt")
    File.write!(path, Enum.join(Enum.map(1..10, &"line-#{&1}"), "\n"))

    assert {:ok, body, ui} =
             Read.execute(%{"path" => "big.txt", "offset" => 3, "limit" => 2}, ctx)

    assert body =~ "line-3"
    assert body =~ "line-4"
    refute body =~ "line-5"

    assert ui.payload.line_range == {3, 4}
  end

  test "offset slices keep REAL file line numbers (not restarting at 1)", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "big.txt")
    File.write!(path, Enum.join(Enum.map(1..10, &"line-#{&1}"), "\n"))

    assert {:ok, body, _ui} =
             Read.execute(%{"path" => "big.txt", "offset" => 3, "limit" => 2}, ctx)

    # The prefix must be the file's own line number so the model can cite
    # and re-read exact ranges.
    assert body =~ "3\tline-3"
    assert body =~ "4\tline-4"
  end

  test "a huge code file WITHOUT offset returns an outline with line ranges", %{
    dir: dir,
    ctx: ctx
  } do
    path = Path.join(dir, "huge.ex")

    content =
      Enum.map_join(1..400, "\n", fn i ->
        "  def fun_#{i}(x) do\n" <>
          String.duplicate("    x = x + 1 # padding padding padding padding\n", 4) <> "  end\n"
      end)

    File.write!(path, "defmodule Huge do\n" <> content <> "\nend\n")

    assert {:ok, body, _ui} = Read.execute(%{"path" => "huge.ex"}, ctx)

    # Compact outline instead of a context-flooding dump…
    assert String.length(body) < 17_000
    assert body =~ "outline"
    assert body =~ "offset"
    # …with line-ranged entries pointing back into the file.
    assert body =~ ~r/lines 1[–-]/
    assert body =~ "defmodule Huge"
    assert body =~ "def fun_1"
  end

  test "a huge file with NO structure falls back to head + explicit marker", %{
    dir: dir,
    ctx: ctx
  } do
    path = Path.join(dir, "huge.txt")
    File.write!(path, String.duplicate("plain data row with some content here\n", 3_000))

    assert {:ok, body, _ui} = Read.execute(%{"path" => "huge.txt"}, ctx)

    assert String.length(body) < 17_000
    assert body =~ "truncated"
    assert body =~ "offset"
    assert body =~ "1\tplain data"
  end

  test "an explicit huge window is still capped", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "huge.txt")
    File.write!(path, String.duplicate("plain data row with some content here\n", 3_000))

    assert {:ok, body, _ui} =
             Read.execute(%{"path" => "huge.txt", "offset" => 1, "limit" => 99_999}, ctx)

    assert String.length(body) < 17_000
    assert body =~ "truncated"
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

    test "refuses to read through a symlink pointing outside the roots",
         %{root: root, outside: outside, ctx: ctx} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      assert {:error, {:path_outside_roots, _}} = Read.execute(%{"path" => "leak"}, ctx)
    end

    test "still reads through a symlink that stays inside the roots",
         %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "real.txt"), "inside")
      File.ln_s!(Path.join(root, "real.txt"), Path.join(root, "alias"))

      assert {:ok, body, _ui} = Read.execute(%{"path" => "alias"}, ctx)
      assert body =~ "inside"
    end
  end
end
