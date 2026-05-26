if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ExAthena.Upgrade do
    @shortdoc "Runs ExAthena upgrade migrations between two versions."

    @moduledoc """
    Igniter upgrader task. Invoked automatically by
    `mix igniter.upgrade ex_athena` after the dependency is bumped;
    can also be invoked directly via `mix ex_athena.upgrade <from> <to>`.

    Each migration is keyed by the *target* version and runs only when
    the upgrade range crosses that version. See
    `Igniter.Upgrades.run/5` for the routing semantics.

    ## Migrations

      * **`0.4.0`** — informs about the v0.4 breaking change for direct
        callers of the six built-in tools (`Read`, `Edit`, `Bash`,
        `Glob`, `Grep`, `WebFetch`) whose `execute/2` return shape
        changed from `{:ok, text}` to `{:ok, text, ui}`. Loop-driven
        callers are unaffected. Also scaffolds `.exathena/.gitignore`
        so session JSONL logs and the file-history snapshots aren't
        accidentally committed.
      * **`0.12.0`** — notices that the TUI/web deps (`ex_ratatui`,
        `phoenix`, `phoenix_live_view`, `bandit`) became `optional`, so
        consumers who use `mix athena.chat` / `mix athena.web` must add
        the deps to their own `mix.exs`. Library-only consumers are
        unaffected.
    """

    use Igniter.Mix.Task

    @example "mix ex_athena.upgrade 0.3.1 0.4.0"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ex_athena,
        example: @example,
        positional: [:from, :to],
        schema: [],
        defaults: [],
        aliases: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      arguments = igniter.args.positional
      options = igniter.args.options

      upgrades = %{
        "0.4.0" => [&upgrade_0_3_to_0_4/2],
        "0.12.0" => [&upgrade_0_11_to_0_12/2]
      }

      Igniter.Upgrades.run(igniter, arguments.from, arguments.to, upgrades, options)
    end

    # ── 0.3.x → 0.4.0 migration ──────────────────────────────────────

    defp upgrade_0_3_to_0_4(igniter, _opts) do
      igniter
      |> ensure_exathena_gitignore()
      |> notice_tool_result_split()
      |> notice_new_features()
    end

    # ── 0.11.x → 0.12.0 migration ────────────────────────────────────

    defp upgrade_0_11_to_0_12(igniter, _opts) do
      notice_optional_frontend_deps(igniter)
    end

    # v0.12 marked the TUI/web stack `optional`, so the core library no
    # longer pulls in ex_ratatui / Phoenix / Bandit transitively. That's
    # a silent footgun for anyone who relied on `mix athena.chat` or
    # `mix athena.web`: after the bump those tasks fail to start unless
    # the consumer adds the deps to their own mix.exs. We can't add deps
    # for them (we don't know if they want the TUI, the web UI, or
    # neither), so we surface a notice with the exact dep list.
    defp notice_optional_frontend_deps(igniter) do
      Igniter.add_notice(igniter, """
      ⚠ v0.12 packaging change — TUI/web deps are now optional.

      `ex_ratatui`, `phoenix`, `phoenix_live_view`, and `bandit` are
      marked `optional: true`, so the core agent loop no longer pulls
      them in transitively — library consumers stay lean.

      If you use the interactive front-ends, add the deps you need to
      your own mix.exs:

          # interactive terminal TUI — `mix athena.chat`
          {:ex_ratatui, "~> 0.10"},

          # Phoenix LiveView web UI — `mix athena.web`
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 1.0"},
          {:bandit, "~> 1.5"},

      Then run `mix deps.get`. If you only use ExAthena as a library
      (via `ExAthena.run/2` / `Loop.run/2`), no action is needed.

      See CHANGELOG.md (v0.12.0 → Packaging) for details.
      """)
    end

    # Scaffold `.exathena/.gitignore` so users don't accidentally commit
    # session JSONL logs, file-history snapshots, or the worktree cache.
    # Idempotent: skipped if the file already exists.
    defp ensure_exathena_gitignore(igniter) do
      path = ".exathena/.gitignore"

      if Igniter.exists?(igniter, path) do
        igniter
      else
        body = """
        # ex_athena runtime artifacts — should not be committed.
        sessions/
        file-history/
        """

        igniter
        |> Igniter.create_new_file(path, body, on_exists: :skip)
        |> Igniter.add_notice("""
        Created .exathena/.gitignore — keeps session logs and
        file-history snapshots out of git.
        """)
      end
    end

    # The single breaking change in v0.4 is the tool-result split: six
    # built-in tools now return `{:ok, text, ui}` 3-tuples. We can't
    # reliably auto-rewrite `{:ok, _} = Tool.execute(...)` patterns —
    # the user might intentionally be matching only-success-or-error.
    # Instead we surface a notice with the exact list and a pointer to
    # the migration section in the changelog.
    defp notice_tool_result_split(igniter) do
      Igniter.add_notice(igniter, """
      ⚠ v0.4 breaking change — tool-result split (PR3b).

      Six built-in tools now return a 3-tuple instead of a 2-tuple
      from their `execute/2` callback:

        ExAthena.Tools.Read     {:ok, text} -> {:ok, text, ui}
        ExAthena.Tools.Edit     {:ok, text} -> {:ok, text, ui}
        ExAthena.Tools.Bash     {:ok, text} -> {:ok, text, ui}
        ExAthena.Tools.Glob     {:ok, text} -> {:ok, text, ui}
        ExAthena.Tools.Grep     {:ok, text} -> {:ok, text, ui}
        ExAthena.Tools.WebFetch {:ok, text} -> {:ok, text, ui}

      `ui` is `%{kind: atom(), payload: map()}` — `:diff`, `:file`,
      `:process`, `:matches`, `:webpage` respectively. The model
      still receives `text`; hosts get a `:tool_ui` event with `ui`.

      Direct callers of these tools' `execute/2` need to update their
      pattern matches:

          # before
          {:ok, body} = ExAthena.Tools.Read.execute(args, ctx)

          # after
          {:ok, body, _ui} = ExAthena.Tools.Read.execute(args, ctx)

      Code that goes through `Loop.run/2` / `ExAthena.run/2` is
      unaffected — `Result.text` still surfaces the LLM-facing string.

      See CHANGELOG.md (v0.4.0 → PR3b) for the full migration notes.
      """)
    end

    defp notice_new_features(igniter) do
      Igniter.add_notice(igniter, """
      ✨ ExAthena v0.4 — new features available

      • Memory: drop AGENTS.md at your project root for project-wide
        rules. See guides/memory_and_skills.md.
      • Skills: drop SKILL.md files under .exathena/skills/<name>/
        for progressive-disclosure knowledge.
      • Custom agents: define subagents in .exathena/agents/<name>.md
        with optional :worktree isolation.
      • Compaction pipeline: five-stage pipeline replaces the
        single-stage compactor; reactive recovery on prompt-too-long.
      • New permission modes: :accept_edits, :trusted (with
        :respect_denylist knob).
      • 14 hook events with {:inject, msg} / {:transform, prompt}
        return values. See guides/hooks_reference.md.
      • Session storage: pass `store: :jsonl` for durable sessions
        with Session.resume/2. File-checkpointing + Checkpoint.rewind/3
        for /undo.

      Full guide list: https://hexdocs.pm/ex_athena.
      """)
    end
  end
else
  defmodule Mix.Tasks.ExAthena.Upgrade do
    @shortdoc "Runs ExAthena upgrade migrations (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix ex_athena.upgrade requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}

      Then run `mix deps.get` and retry.
      """)
    end
  end
end
