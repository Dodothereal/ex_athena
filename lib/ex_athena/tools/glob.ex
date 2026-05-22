defmodule ExAthena.Tools.Glob do
  @moduledoc """
  Finds files matching a glob pattern, relative to `ctx.cwd`.

  Arguments:

    * `pattern` (required) — `Path.wildcard/1`-compatible pattern, e.g. `lib/**/*.ex`.
    * `max_results` (optional, default 200) — cap on the number of paths returned.
    * `include_artifacts` (optional, default false) — when true, returns paths under
      `_build/`, `deps/`, `node_modules/`, `.git/`, `priv/static/`, and `tmp/` too.

  Result is a newline-separated list of paths relative to `ctx.cwd`.
  """

  @behaviour ExAthena.Tool

  @default_max 200
  @hard_cap 5_000

  @artifact_dirs ExAthena.Permissions.artifact_dirs()

  @impl true
  def name, do: "glob"

  @impl true
  def description,
    do: "Find files matching a glob pattern (e.g. `lib/**/*.ex`) under the working directory."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Path.wildcard pattern"},
        max_results: %{type: "integer", description: "cap on results (default 200)"},
        include_artifacts: %{
          type: "boolean",
          description:
            "Include `_build/`, `deps/`, `node_modules/`, `.git/`, `priv/static/`, `tmp/` paths (default false)"
        }
      },
      required: ["pattern"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(%{"pattern" => pattern} = args, %{cwd: cwd}) when is_binary(pattern) do
    max = clamp(Map.get(args, "max_results", @default_max))
    include_artifacts = Map.get(args, "include_artifacts", false) == true

    results =
      cwd
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, cwd))
      |> filter_artifacts(include_artifacts)
      |> Enum.take(max)

    ui = %{
      kind: :matches,
      payload: %{
        pattern: pattern,
        count: length(results),
        items: results
      }
    }

    {:ok, format(results), ui}
  end

  def execute(_, _), do: {:error, :missing_pattern}

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @hard_cap)
  defp clamp(_), do: @default_max

  defp filter_artifacts(paths, true), do: paths

  defp filter_artifacts(paths, false) do
    Enum.reject(paths, &artifact_path?/1)
  end

  defp artifact_path?(path) do
    Enum.any?(@artifact_dirs, fn dir ->
      # Matches at root (`_build/...`) and nested (`web/_build/...`) — the
      # leading-slash check is what catches Phoenix-in-subdir layouts.
      String.starts_with?(path, dir) or String.contains?(path, "/" <> dir)
    end)
  end

  defp format([]), do: "(no matches)"
  defp format(results), do: Enum.join(results, "\n")
end
