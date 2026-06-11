defmodule ExAthena.Tools.UsageRulesTest do
  use ExUnit.Case, async: true

  alias ExAthena.Tools.UsageRules
  alias ExAthena.ToolContext

  setup do
    dir = Path.join(System.tmp_dir!(), "usage_rules_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "deps/foo"))
    File.mkdir_p!(Path.join(dir, "deps/bar/usage-rules"))
    File.write!(Path.join(dir, "deps/foo/usage-rules.md"), "# Foo rules\nUse Foo wisely.")

    File.write!(
      Path.join(dir, "deps/bar/usage-rules/html.md"),
      "# Bar HTML rules\nEscape everything."
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, ctx: ToolContext.new(cwd: dir)}
  end

  test "is a registered builtin and allowed in :plan", %{} do
    assert ExAthena.Tools.UsageRules in ExAthena.Tools.builtins()
    assert "usage_rules" in ExAthena.Permissions.readonly_tools()
  end

  test "with no package, lists available rule sets (main + nested topics)", %{ctx: ctx} do
    assert {:ok, text} = UsageRules.execute(%{}, ctx)
    assert text =~ "foo"
    assert text =~ "bar:html"
  end

  test "reads a top-level package's usage-rules.md", %{ctx: ctx} do
    assert {:ok, text} = UsageRules.execute(%{"package" => "foo"}, ctx)
    assert text =~ "Use Foo wisely."
  end

  test "reads a nested <pkg>:<topic> rule file", %{ctx: ctx} do
    assert {:ok, text} = UsageRules.execute(%{"package" => "bar:html"}, ctx)
    assert text =~ "Escape everything."
  end

  test "unknown package returns an error", %{ctx: ctx} do
    assert {:error, msg} = UsageRules.execute(%{"package" => "nope"}, ctx)
    assert msg =~ "nope"
  end

  test "rejects path traversal in the package name", %{ctx: ctx} do
    assert {:error, _} = UsageRules.execute(%{"package" => "../../etc/passwd"}, ctx)
    assert {:error, _} = UsageRules.execute(%{"package" => "foo/../bar"}, ctx)
  end

  test "empty deps directory reports nothing found", %{} do
    empty = Path.join(System.tmp_dir!(), "ur_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    assert {:ok, text} = UsageRules.execute(%{}, ToolContext.new(cwd: empty))
    assert text =~ "No usage rules"
  end
end
