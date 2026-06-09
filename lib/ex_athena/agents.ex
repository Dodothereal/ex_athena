defmodule ExAthena.Agents do
  @moduledoc """
  Custom agent definitions loaded from YAML/markdown files.

  An *agent* is a named bundle of run options — model, provider,
  tools, permissions, mode, isolation strategy, and a system-prompt
  addendum — that callers can spawn by name via
  `ExAthena.Tools.SpawnAgent.execute/2` with `agent: "<name>"`.

  This is opencode's `.opencode/agents/<name>.md` pattern adapted to
  ex_athena. The Claude Code paper documents the same idea
  (`.claude/agents/*.md`) for delegating bounded tasks.

  ## Layout

      ~/.config/ex_athena/agents/<name>.md   # user-level
      <cwd>/.exathena/agents/<name>.md       # project-level
      priv/agents/<name>.md                  # builtin fallbacks (ship with the package)

  Project agents override user-level agents with the same name; the
  built-in fallbacks (`general`, `explore`, `plan`, `research`) are used
  only when the host hasn't defined one with the same name.

  ## Frontmatter schema

      ---
      name: explore
      description: Read-only fast investigation
      model: claude-haiku-4-5
      provider: anthropic
      tools: [read, glob, grep, web_fetch]
      permissions: plan
      mode: react
      isolation: in_process
      ---

      You are a read-only research assistant. Walk the codebase and
      report findings concisely. Do not modify any files.

  Only `name` is required. Anything else inherits from the spawning
  parent (provider, model, tools, etc.) or hard-coded defaults
  (`mode: :react`, `isolation: :in_process`, `permissions: :default`).
  """

  alias ExAthena.Agents.Definition

  @user_dir Path.expand("~/.config/ex_athena/agents")
  @project_subdir ".exathena/agents"
  @builtin_dir Application.app_dir(:ex_athena, "priv/agents")

  @doc """
  Discover all agent definitions for `cwd`.

  Returns a map keyed by name. Resolution: builtin → user → project,
  later sources overriding earlier ones.

  ## Options

    * `:user_dir` — override the user-level agents directory.
    * `:project_dir` — override the project-level directory.
    * `:builtin_dir` — override the builtin fallbacks (mainly for
      tests).
  """
  @spec discover(String.t(), keyword()) :: %{String.t() => Definition.t()}
  def discover(cwd, opts \\ []) when is_binary(cwd) do
    user_dir = Keyword.get(opts, :user_dir, @user_dir)
    project_dir = Keyword.get(opts, :project_dir, Path.join(cwd, @project_subdir))
    builtin_dir = Keyword.get(opts, :builtin_dir, @builtin_dir)

    %{}
    |> merge(load_dir(builtin_dir))
    |> merge(load_dir(user_dir))
    |> merge(load_dir(project_dir))
  end

  @doc "Look up an agent by name. Returns `{:ok, def}` or `{:error, :not_found}`."
  @spec fetch(map(), String.t()) :: {:ok, Definition.t()} | {:error, :not_found}
  def fetch(agents, name) when is_map(agents) and is_binary(name) do
    case Map.get(agents, name) do
      nil -> {:error, :not_found}
      def -> {:ok, def}
    end
  end

  @doc """
  Apply a definition's frontmatter to a base keyword list of run
  options. Definition fields override the parent's values when set;
  unset fields pass through.
  """
  @spec apply_to_opts(Definition.t(), keyword()) :: keyword()
  def apply_to_opts(%Definition{} = def, opts) when is_list(opts) do
    opts
    |> maybe_put(:model, def.model)
    |> maybe_put(:provider, def.provider)
    |> maybe_put(:tools, def.tools)
    |> maybe_put(:phase, def.permissions)
    |> maybe_put(:mode, def.mode)
    |> merge_system_prompt(def.system_prompt)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp merge_system_prompt(opts, nil), do: opts
  defp merge_system_prompt(opts, ""), do: opts

  defp merge_system_prompt(opts, addendum) do
    new_prompt =
      case Keyword.get(opts, :system_prompt) do
        nil -> addendum
        existing -> existing <> "\n\n" <> addendum
      end

    Keyword.put(opts, :system_prompt, new_prompt)
  end

  defp merge(acc, []), do: acc

  defp merge(acc, list) when is_list(list) do
    Enum.reduce(list, acc, fn %Definition{name: name} = def, m -> Map.put(m, name, def) end)
  end

  defp load_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(fn entry -> load_file(Path.join(dir, entry)) end)

      {:error, _} ->
        []
    end
  end

  defp load_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(raw),
         {:ok, parsed} <- parse_frontmatter(frontmatter) do
      [Definition.from_parsed(parsed, body, path)]
    else
      _ -> []
    end
  end

  defp split_frontmatter(raw) do
    case String.split(raw, ~r/^---\s*\n/m, parts: 3) do
      ["", front, body] -> {:ok, front, String.trim_leading(body, "\n")}
      _ -> :no_frontmatter
    end
  end

  defp parse_frontmatter(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          key = k |> String.trim() |> String.downcase()
          val = v |> String.trim() |> coerce()
          {:cont, {:ok, Map.put(acc, key, val)}}

        _ ->
          {:halt, :bad_frontmatter}
      end
    end)
  end

  defp coerce("true"), do: true
  defp coerce("false"), do: false

  defp coerce("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [items, _] ->
        items
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        rest
    end
  end

  defp coerce(<<?", _::binary>> = quoted) do
    quoted |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  defp coerce(other), do: other
end
