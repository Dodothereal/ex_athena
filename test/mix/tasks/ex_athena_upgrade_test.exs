defmodule Mix.Tasks.ExAthena.UpgradeTest do
  @moduledoc """
  Verifies the v0.3.x → v0.4.0 Igniter upgrader: notices about the
  tool-result-split breaking change, lists new v0.4 features, and
  scaffolds `.exathena/.gitignore` if missing.
  """
  # async: false because Igniter compose_task briefly mutates Application
  # env via try/after; parallel ConfigTest cases that read :ex_athena env
  # would race.
  use ExUnit.Case, async: false

  import Igniter.Test

  describe "0.3.1 -> 0.4.0" do
    test "scaffolds .exathena/.gitignore" do
      test_project()
      |> Igniter.compose_task("ex_athena.upgrade", ["0.3.1", "0.4.0"])
      |> assert_creates(".exathena/.gitignore", """
      # ex_athena runtime artifacts — should not be committed.
      sessions/
      file-history/
      """)
    end

    test "skips .exathena/.gitignore when one already exists" do
      base =
        test_project(
          files: %{
            ".exathena/.gitignore" => "# user customised\n"
          }
        )

      igniter = Igniter.compose_task(base, "ex_athena.upgrade", ["0.3.1", "0.4.0"])
      assert_unchanged(igniter, ".exathena/.gitignore")
    end

    test "emits a notice about the tool-result-split breaking change" do
      igniter =
        test_project()
        |> Igniter.compose_task("ex_athena.upgrade", ["0.3.1", "0.4.0"])

      notice = Enum.join(igniter.notices, "\n")
      assert notice =~ "tool-result split"
      assert notice =~ "ExAthena.Tools.Read"
      assert notice =~ "ExAthena.Tools.Edit"
      assert notice =~ "ExAthena.Tools.Bash"
      assert notice =~ "ExAthena.Tools.Glob"
      assert notice =~ "ExAthena.Tools.Grep"
      assert notice =~ "ExAthena.Tools.WebFetch"
      assert notice =~ "Loop.run/2"
    end

    test "emits a notice listing new v0.4 features" do
      igniter =
        test_project()
        |> Igniter.compose_task("ex_athena.upgrade", ["0.3.1", "0.4.0"])

      notice = Enum.join(igniter.notices, "\n")
      assert notice =~ "Memory"
      assert notice =~ "AGENTS.md"
      assert notice =~ "Skills"
      assert notice =~ "Custom agents"
      assert notice =~ "Compaction pipeline"
      assert notice =~ "permission modes"
      assert notice =~ "hook events"
      assert notice =~ "Session storage"
    end
  end

  describe "0.11.0 -> 0.12.0 (optional TUI/web deps)" do
    test "emits a notice that the TUI/web deps are now optional" do
      igniter =
        test_project()
        |> Igniter.compose_task("ex_athena.upgrade", ["0.11.0", "0.12.0"])

      notice = Enum.join(igniter.notices, "\n")
      assert notice =~ "optional"
      assert notice =~ "ex_ratatui"
      assert notice =~ "phoenix"
      assert notice =~ "phoenix_live_view"
      assert notice =~ "bandit"
      assert notice =~ "mix athena.chat"
      assert notice =~ "mix athena.web"
    end

    test "does not emit the v0.4 tool-result-split notice" do
      igniter =
        test_project()
        |> Igniter.compose_task("ex_athena.upgrade", ["0.11.0", "0.12.0"])

      # The 0.4.0 migration must not run — its target falls outside
      # `> 0.11.0 and <= 0.12.0`.
      notice = Enum.join(igniter.notices, "\n")
      refute notice =~ "tool-result split"
    end
  end

  describe "version routing (Igniter.Upgrades.run/5)" do
    test "0.4.0 -> 0.4.0 is a no-op (range is exclusive of from)" do
      igniter =
        test_project()
        |> Igniter.compose_task("ex_athena.upgrade", ["0.4.0", "0.4.0"])

      # No notices, no files created — every migration's target version
      # falls outside `> 0.4.0 and <= 0.4.0`.
      assert igniter.notices == []
      refute Map.has_key?(igniter.rewrite.sources, ".exathena/.gitignore")
    end

    test "0.12.0 -> 0.12.2 is a no-op (no migration in the exclusive range)" do
      igniter =
        test_project()
        |> Igniter.compose_task("ex_athena.upgrade", ["0.12.0", "0.12.2"])

      # The 0.12.0 migration's target is 0.12.0, which is outside
      # `> 0.12.0 and <= 0.12.2`, so a within-0.12 bump emits nothing.
      assert igniter.notices == []
    end
  end
end
