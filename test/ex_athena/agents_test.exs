defmodule ExAthena.AgentsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Agents
  alias ExAthena.Agents.Definition

  setup do
    cwd = Path.join(System.tmp_dir!(), "agents_proj_#{System.unique_integer([:positive])}")
    user = Path.join(System.tmp_dir!(), "agents_user_#{System.unique_integer([:positive])}")
    builtin = Path.join(System.tmp_dir!(), "agents_builtin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(cwd, ".exathena/agents"))
    File.mkdir_p!(user)
    File.mkdir_p!(builtin)

    on_exit(fn ->
      File.rm_rf!(cwd)
      File.rm_rf!(user)
      File.rm_rf!(builtin)
    end)

    {:ok, cwd: cwd, user: user, builtin: builtin}
  end

  defp write(dir, name, body) do
    File.mkdir_p!(dir)
    # Ensure a trailing newline so the closing `---` is line-anchored.
    File.write!(Path.join(dir, "#{name}.md"), body <> "\n")
  end

  describe "discover/2" do
    test "returns the builtin general/explore/plan/research when shipped agents are loaded", %{
      cwd: cwd,
      user: user
    } do
      # Use the real `priv/agents/` so we exercise the package's defaults.
      agents = Agents.discover(cwd, user_dir: user)

      assert %{
               "general" => %Definition{},
               "explore" => %Definition{tools: explore_tools},
               "plan" => %Definition{tools: plan_tools},
               "research" => %Definition{tools: research_tools, permissions: :plan}
             } = agents

      # web_search reaches the read-only research workers.
      assert "web_search" in explore_tools
      assert "web_search" in plan_tools
      assert "web_search" in research_tools
    end

    test "loads a custom project agent and prefers it over builtins", %{
      cwd: cwd,
      user: user
    } do
      # Override the builtin "general" with a project-level redefinition.
      write(Path.join(cwd, ".exathena/agents"), "general", """
      ---
      name: general
      description: Project-overridden general
      ---
      Custom body.
      """)

      agents = Agents.discover(cwd, user_dir: user)
      assert agents["general"].description == "Project-overridden general"
      assert agents["general"].system_prompt =~ "Custom body."
    end

    test "project beats user beats builtin", %{cwd: cwd, user: user, builtin: builtin} do
      write(builtin, "demo", "---\nname: demo\ndescription: builtin\n---")
      write(user, "demo", "---\nname: demo\ndescription: user\n---")

      write(
        Path.join(cwd, ".exathena/agents"),
        "demo",
        "---\nname: demo\ndescription: project\n---"
      )

      agents = Agents.discover(cwd, user_dir: user, builtin_dir: builtin)
      assert agents["demo"].description == "project"
    end
  end

  describe "fetch/2" do
    test "returns :not_found for unknown agents" do
      assert {:error, :not_found} = Agents.fetch(%{}, "missing")
    end

    test "returns the definition" do
      def = %Definition{name: "x", description: "y"}
      assert {:ok, ^def} = Agents.fetch(%{"x" => def}, "x")
    end
  end

  describe "apply_to_opts/2" do
    test "merges definition fields into opts" do
      def = %Definition{
        name: "explore",
        description: "ro",
        model: "claude-haiku-4-5",
        tools: ["read", "glob"],
        permissions: :plan,
        mode: :react,
        system_prompt: "Be concise."
      }

      opts =
        Agents.apply_to_opts(def,
          provider: :mock,
          system_prompt: "You are a helper.",
          tools: ["bash"]
        )

      # Definition fields override.
      assert opts[:model] == "claude-haiku-4-5"
      assert opts[:tools] == ["read", "glob"]
      assert opts[:phase] == :plan
      assert opts[:mode] == :react

      # Provider passes through (definition didn't set one).
      assert opts[:provider] == :mock

      # System prompt is appended, not replaced.
      assert opts[:system_prompt] == "You are a helper.\n\nBe concise."
    end

    test "leaves opts untouched when the definition doesn't set a field" do
      def = %Definition{name: "x", description: "y"}
      opts = Agents.apply_to_opts(def, model: "default-model", provider: :mock)
      assert opts[:model] == "default-model"
      assert opts[:provider] == :mock
    end
  end
end
