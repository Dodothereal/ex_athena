defmodule ExAthena.Tools.GlobGrepTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.{Glob, Grep}

  setup do
    dir = Path.join(System.tmp_dir!(), "gg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\n  def foo, do: :bar\nend\n")
    File.write!(Path.join(dir, "b.ex"), "defmodule B do\n  def baz, do: :qux\nend\n")
    File.write!(Path.join(dir, "sub/c.ex"), "defmodule C do\n  def foo, do: :bar\nend\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, ctx: ToolContext.new(cwd: dir)}
  end

  test "Glob lists files under a pattern", %{ctx: ctx} do
    assert {:ok, output, ui} = Glob.execute(%{"pattern" => "**/*.ex"}, ctx)
    assert output =~ "a.ex"
    assert output =~ "b.ex"
    assert output =~ "sub/c.ex"

    assert ui.kind == :matches
    assert ui.payload.count >= 3
  end

  test "Glob returns '(no matches)' on empty", %{ctx: ctx} do
    assert {:ok, "(no matches)", %{kind: :matches, payload: %{count: 0}}} =
             Glob.execute(%{"pattern" => "*.nope"}, ctx)
  end

  test "Glob requires pattern", %{ctx: ctx} do
    assert {:error, :missing_pattern} = Glob.execute(%{}, ctx)
  end

  test "Glob respects max_results cap", %{ctx: ctx} do
    assert {:ok, output, _ui} =
             Glob.execute(%{"pattern" => "**/*.ex", "max_results" => 1}, ctx)

    # Only one line with a filename
    assert length(String.split(output, "\n", trim: true)) == 1
  end

  test "Grep finds matching lines", %{ctx: ctx} do
    assert {:ok, output, ui} = Grep.execute(%{"pattern" => "def foo"}, ctx)
    assert output =~ "a.ex"
    assert output =~ "sub/c.ex"

    assert ui.kind == :matches
    assert ui.payload.pattern == "def foo"
    assert ui.payload.count >= 2
  end

  test "Grep returns '(no matches)' when empty", %{ctx: ctx} do
    assert {:ok, output, %{kind: :matches, payload: %{count: 0}}} =
             Grep.execute(%{"pattern" => "zzzzzzzz"}, ctx)

    assert output =~ "(no matches)"
  end

  test "Grep requires pattern", %{ctx: ctx} do
    assert {:error, :missing_pattern} = Grep.execute(%{}, ctx)
  end

  describe "build-artifact filtering" do
    setup do
      dir = Path.join(System.tmp_dir!(), "gg_filter_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "lib"))
      File.mkdir_p!(Path.join(dir, "_build/dev/lib/phoenix/priv/templates/phx.gen.auth"))
      File.mkdir_p!(Path.join(dir, "deps/phoenix/lib"))
      File.mkdir_p!(Path.join(dir, "node_modules/foo"))
      File.mkdir_p!(Path.join(dir, ".git"))
      File.mkdir_p!(Path.join(dir, "priv/static/assets"))
      File.mkdir_p!(Path.join(dir, "tmp"))

      File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do\n  def needle, do: :ok\nend\n")

      File.write!(
        Path.join(dir, "_build/dev/lib/phoenix/priv/templates/phx.gen.auth/auth.ex"),
        "defmodule Phx.Auth do\n  def needle, do: :ok\nend\n"
      )

      File.write!(
        Path.join(dir, "deps/phoenix/lib/phoenix.ex"),
        "defmodule Phoenix do\n  def needle, do: :ok\nend\n"
      )

      File.write!(Path.join(dir, "node_modules/foo/bar.js"), "// needle\n")
      File.write!(Path.join(dir, ".git/HEAD"), "ref: needle\n")
      File.write!(Path.join(dir, "priv/static/assets/app.css"), "/* needle */\n")
      File.write!(Path.join(dir, "tmp/scratch.ex"), "defmodule Scratch do\n  def needle, do: :ok\nend\n")

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, ctx: ToolContext.new(cwd: dir)}
    end

    test "Glob excludes _build, deps, node_modules, .git, priv/static, tmp by default",
         %{ctx: ctx} do
      {:ok, output, ui} = Glob.execute(%{"pattern" => "**/*.ex"}, ctx)

      assert output =~ "lib/app.ex"
      refute output =~ "_build/"
      refute output =~ "deps/"
      refute output =~ "tmp/"
      assert ui.payload.count == 1
    end

    test "Glob honors include_artifacts: true and returns build/dep paths too",
         %{ctx: ctx} do
      {:ok, output, _ui} =
        Glob.execute(%{"pattern" => "**/*.ex", "include_artifacts" => true}, ctx)

      assert output =~ "lib/app.ex"
      assert output =~ "_build/"
      assert output =~ "deps/"
      assert output =~ "tmp/"
    end

    test "Grep excludes the same artifact directories by default", %{ctx: ctx} do
      {:ok, output, ui} = Grep.execute(%{"pattern" => "needle"}, ctx)

      assert output =~ "lib/app.ex"
      refute output =~ "_build/"
      refute output =~ "deps/"
      refute output =~ "node_modules/"
      refute output =~ ".git/"
      refute output =~ "priv/static/"
      refute output =~ "tmp/"
      assert ui.payload.count >= 1
    end

    test "Grep honors include_artifacts: true", %{ctx: ctx} do
      {:ok, output, _ui} =
        Grep.execute(%{"pattern" => "needle", "include_artifacts" => true}, ctx)

      assert output =~ "lib/app.ex"
      assert output =~ "_build/"
      assert output =~ "deps/"
    end
  end
end
