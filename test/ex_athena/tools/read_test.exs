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
end
