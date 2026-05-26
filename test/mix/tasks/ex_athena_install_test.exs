defmodule Mix.Tasks.ExAthena.InstallTest do
  @moduledoc """
  Verifies the installer's Igniter task: writes provider config defaults,
  scaffolds `.exathena/.gitignore`, and surfaces an explanatory notice.

  Uses `Igniter.Test.test_project/1` so we exercise the full Igniter
  pipeline without touching the real filesystem.
  """
  # async: false because Igniter.Project.Config.configure/6 briefly
  # mutates Application env via try/after — that race-conditions with
  # parallel ConfigTest cases that also read :ex_athena env.
  use ExUnit.Case, async: false

  import Igniter.Test

  test "writes default_provider + per-provider config to config/config.exs" do
    igniter =
      test_project()
      |> Igniter.compose_task("ex_athena.install", [])

    # Igniter normalises consecutive `config :ex_athena, ...` calls into a
    # single nested keyword block, so we assert on substrings of the
    # rendered config rather than line-anchored diff patches.
    config = render_source(igniter, "config/config.exs")
    assert config =~ "default_provider: :ollama"
    assert config =~ "ollama:"
    assert config =~ "base_url: \"http://localhost:11434\""
    assert config =~ "model: \"llama3.1\""
    assert config =~ "openai_compatible:"
    assert config =~ "https://api.openai.com/v1"
    assert config =~ "claude:"
    assert config =~ "claude-opus-4-5"
  end

  defp render_source(igniter, path) do
    igniter.rewrite.sources
    |> Map.get(path)
    |> Rewrite.Source.get(:content)
  end

  test "scaffolds .exathena/.gitignore" do
    test_project()
    |> Igniter.compose_task("ex_athena.install", [])
    |> assert_creates(".exathena/.gitignore", """
    # ex_athena runtime artifacts — should not be committed.
    sessions/
    file-history/
    """)
  end

  test "surfaces a notice that mentions core features" do
    igniter =
      test_project()
      |> Igniter.compose_task("ex_athena.install", [])

    notice = Enum.join(igniter.notices, "\n")
    assert notice =~ "ExAthena installed"
    assert notice =~ "Memory"
    assert notice =~ "AGENTS.md"
    assert notice =~ "Skills"
    assert notice =~ "Sessions"
  end

  test "notice points at the optional TUI/web front-ends and their deps" do
    igniter =
      test_project()
      |> Igniter.compose_task("ex_athena.install", [])

    notice = Enum.join(igniter.notices, "\n")
    assert notice =~ "mix athena.chat"
    assert notice =~ "mix athena.web"
    assert notice =~ "optional"
    assert notice =~ "ex_ratatui"
  end

  test "is idempotent — re-running preserves user changes" do
    base =
      test_project(
        files: %{
          ".exathena/.gitignore" => "user-customised\n"
        }
      )

    igniter = Igniter.compose_task(base, "ex_athena.install", [])

    # Existing file is left untouched (on_exists: :skip).
    assert_unchanged(igniter, ".exathena/.gitignore")
  end
end
