if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ExAthena.Install do
    @shortdoc "Installs ExAthena — writes sensible config defaults."

    @moduledoc """
    Installs ExAthena into your project.

    Run once after adding `{:ex_athena, "~> 0.18"}` to `mix.exs`, or via Igniter:

        mix igniter.install ex_athena
        mix ex_athena.install

    ## What it does

      * Writes a `config :ex_athena, default_provider: :ollama` default to
        `config/config.exs` (only if no default is already configured).
      * Writes sensible per-provider defaults for Ollama (base URL pointing at
        `http://localhost:11434`), OpenAI-compatible (`https://api.openai.com/v1`),
        and Claude (picks up `ANTHROPIC_API_KEY` from env).
      * Writes an Ollama `embedding_model:` default (`nomic-embed-text`) so
        `ExAthena.embed/2` works without further setup — the chat `model:` is
        deliberately never a fallback for embeddings, so an unset key means
        `embed/2` errors rather than quietly embedding with the wrong model.
      * Scaffolds `.exathena/.gitignore` so v0.4 runtime artifacts (session
        JSONL logs, file-history snapshots, worktree cache) aren't
        accidentally committed.
      * Does NOT write API keys inline — the installer uses
        `{:system, "VAR"}` tuples so secrets stay in the environment.

    Idempotent: re-running preserves whatever you've already set.

    ## Upgrading

    From an older version of ex_athena, run:

        mix igniter.upgrade ex_athena

    which routes through `mix ex_athena.upgrade` and applies any
    version-specific migrations (e.g. notices about the v0.4
    tool-result-split breaking change).
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ex_athena,
        example: "mix ex_athena.install",
        schema: [],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> configure_default_provider()
      |> configure_ollama()
      |> configure_openai_compatible()
      |> configure_claude()
      |> ensure_exathena_gitignore()
      |> Igniter.add_notice("""
      ExAthena installed.

      Providers
      ─────────
      • Default provider set to :ollama (pointing at http://localhost:11434).
      • To use OpenAI / OpenRouter / LM Studio / llama.cpp, set
        `config :ex_athena, default_provider: :openai_compatible` and point
        base_url + api_key at your endpoint.
      • To use Anthropic Claude, set
        `config :ex_athena, default_provider: :claude` and provide
        ANTHROPIC_API_KEY in the environment.

      Embeddings
      ──────────
      • ExAthena.embed/2 is configured against Ollama with
        embedding_model: "nomic-embed-text". Pull it once:

            ollama pull nomic-embed-text

      • The chat model is never used as a fallback for embeddings, so
        set `embedding_model:` on any other provider you embed with.

      Features available out of the box
      ─────────────────────────────────
      • Memory: drop AGENTS.md at your project root for project-wide
        rules the agent honours on every turn.
      • Skills: drop SKILL.md files under .exathena/skills/<name>/
        for progressive-disclosure knowledge.
      • Agents: define custom subagents in .exathena/agents/<name>.md
        with optional git-worktree isolation.
      • Sessions: pass `store: :jsonl` to ExAthena.Session for durable
        conversations with Session.resume/2.

      Interactive front-ends (optional deps)
      ──────────────────────────────────────
      The TUI and web UI ship as optional deps so the core library stays
      lean. Add the ones you want to your mix.exs, then run mix deps.get:
      • `mix athena.chat` — full-screen terminal TUI. Needs
        {:ex_ratatui, "~> 0.11"}.
      • `mix athena.web` — Phoenix LiveView web UI. Needs
        {:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}, and
        {:bandit, "~> 1.5"}.

      Full docs: https://hexdocs.pm/ex_athena.
      """)
    end

    defp configure_default_provider(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :ex_athena,
        [:default_provider],
        :ollama,
        updater: &keep_existing/1
      )
    end

    defp configure_ollama(igniter) do
      igniter
      |> Igniter.Project.Config.configure(
        "config.exs",
        :ex_athena,
        [:ollama, :base_url],
        "http://localhost:11434",
        updater: &keep_existing/1
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :ex_athena,
        [:ollama, :model],
        "llama3.1",
        updater: &keep_existing/1
      )
      # Embedding models are a different population from chat models, and the
      # chat `model:` is deliberately not a fallback (embedding with a chat
      # model retrieves badly while looking fine), so `embed/2` errors outright
      # when this is unset. `nomic-embed-text` is the recommended local default:
      # its 8192-token context fits function- and module-sized code chunks,
      # where `mxbai-embed-large` truncates at 512.
      |> Igniter.Project.Config.configure(
        "config.exs",
        :ex_athena,
        [:ollama, :embedding_model],
        "nomic-embed-text",
        updater: &keep_existing/1
      )
    end

    defp configure_openai_compatible(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :ex_athena,
        [:openai_compatible, :base_url],
        "https://api.openai.com/v1",
        updater: &keep_existing/1
      )
    end

    defp configure_claude(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :ex_athena,
        [:claude, :model],
        "claude-opus-4-8",
        updater: &keep_existing/1
      )
    end

    # Scaffold a .gitignore for the v0.4 runtime artifact directories
    # so users don't accidentally commit session JSONL logs, file-history
    # snapshots, or the worktree cache. Idempotent: if the file already
    # exists, leave it alone (don't overwrite the user's customisations).
    defp ensure_exathena_gitignore(igniter) do
      path = ".exathena/.gitignore"

      if Igniter.exists?(igniter, path) do
        igniter
      else
        Igniter.create_new_file(
          igniter,
          path,
          """
          # ex_athena runtime artifacts — should not be committed.
          sessions/
          file-history/
          """,
          on_exists: :skip
        )
      end
    end

    # Preserve whatever the user already has.
    defp keep_existing(zipper), do: {:ok, zipper}
  end
else
  defmodule Mix.Tasks.ExAthena.Install do
    @shortdoc "Installs ExAthena (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix ex_athena.install requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}

      Then run `mix deps.get` and retry.
      """)
    end
  end
end
