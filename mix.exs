defmodule ExAthena.MixProject do
  use Mix.Project

  @version "0.14.0"
  @source_url "https://github.com/udin-io/ex_athena"

  def project do
    [
      app: :ex_athena,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ExAthena",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExAthena.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.10"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:claude_code, "~> 0.36", optional: true},
      {:igniter, "~> 0.6", optional: true},
      # Optional — only needed for the interactive TUI (`mix athena.chat`) and the
      # web UI (`mix athena.web`). The core agent loop never starts them, so library
      # consumers aren't forced to pull in Phoenix/Bandit/ex_ratatui.
      {:ex_ratatui, "~> 0.10", optional: true},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp description do
    """
    Provider-agnostic agent loop for Elixir. Drop-in replacement for the Claude
    Code SDK that runs on Ollama, OpenAI-compatible endpoints, llama.cpp, or
    Anthropic itself — same tools, hooks, permissions, and streaming across all
    providers. Includes a full Igniter installer.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      maintainers: ["Peter Shoukry"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting_started.md",
        "guides/providers.md",
        "guides/gemini.md",
        "guides/multimodal.md",
        "guides/tool_calls.md",
        "guides/tools.md",
        "guides/agent_loop.md",
        "guides/memory_and_skills.md",
        "guides/compaction_pipeline.md",
        "guides/hooks_reference.md",
        "guides/permissions.md",
        "guides/agents_subagents.md",
        "guides/sessions_and_checkpoints.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r{guides/.+\.md}
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Core API": [
          ExAthena,
          ExAthena.Config,
          ExAthena.Request,
          ExAthena.Response,
          ExAthena.Result
        ],
        "Agent loop": [
          ExAthena.Loop,
          ExAthena.Loop.Mode,
          ExAthena.Loop.Events,
          ExAthena.Loop.Parallel,
          ExAthena.Loop.State,
          ExAthena.Loop.Terminations,
          ExAthena.Session,
          ExAthena.Structured,
          ExAthena.Budget
        ],
        Modes: [
          ExAthena.Modes.ReAct,
          ExAthena.Modes.PlanAndSolve,
          ExAthena.Modes.Reflexion
        ],
        Messages: [
          ExAthena.Messages,
          ExAthena.Messages.Message,
          ExAthena.Messages.ToolCall,
          ExAthena.Messages.ToolResult
        ],
        "Provider contract": [ExAthena.Provider, ExAthena.Capabilities],
        Providers: [
          ExAthena.Providers.ReqLLM,
          ExAthena.Providers.Mock
        ],
        "Tool calls": [
          ExAthena.ToolCalls,
          ExAthena.ToolCalls.Native,
          ExAthena.ToolCalls.TextTagged
        ],
        "Tool contract": [ExAthena.Tool, ExAthena.ToolContext, ExAthena.Tools],
        "Builtin tools": [
          ExAthena.Tools.Read,
          ExAthena.Tools.Glob,
          ExAthena.Tools.Grep,
          ExAthena.Tools.Write,
          ExAthena.Tools.Edit,
          ExAthena.Tools.Bash,
          ExAthena.Tools.WebFetch,
          ExAthena.Tools.TodoWrite,
          ExAthena.Tools.PlanMode,
          ExAthena.Tools.SpawnAgent,
          ExAthena.Tools.Finish
        ],
        "Memory + Skills": [
          ExAthena.Memory,
          ExAthena.Skills,
          ExAthena.Skills.Skill
        ],
        "Compaction pipeline": [
          ExAthena.Compactor,
          ExAthena.Compactor.Pipeline,
          ExAthena.Compactor.Stage,
          ExAthena.Compactors.Summary,
          ExAthena.Compactors.BudgetReduction,
          ExAthena.Compactors.Snip,
          ExAthena.Compactors.Microcompact,
          ExAthena.Compactors.ContextCollapse
        ],
        "Permissions + hooks": [ExAthena.Permissions, ExAthena.Permissions.Denial, ExAthena.Hooks],
        Agents: [
          ExAthena.Agents,
          ExAthena.Agents.Definition,
          ExAthena.Agents.Worktree,
          ExAthena.Agents.WorktreeSweeper,
          ExAthena.Agents.Sidechain
        ],
        Sessions: [
          ExAthena.Sessions.Store,
          ExAthena.Sessions.Stores.InMemory,
          ExAthena.Sessions.Stores.Jsonl
        ],
        Checkpointing: [
          ExAthena.Checkpoint,
          ExAthena.Checkpoint.Sweeper
        ],
        Streaming: [ExAthena.Streaming, ExAthena.Streaming.Event],
        Errors: [ExAthena.Error],
        MCP: [
          ExAthena.Mcp,
          ExAthena.Mcp.Client,
          ExAthena.Mcp.Protocol,
          ExAthena.Mcp.Transport,
          ExAthena.Mcp.Transport.Stdio,
          ExAthena.Mcp.Transport.Http
        ]
      ]
    ]
  end
end
