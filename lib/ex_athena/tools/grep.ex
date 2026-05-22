defmodule ExAthena.Tools.Grep do
  @moduledoc """
  Search file contents with a regex under `ctx.cwd`.

  Shells out to `rg` (ripgrep) when available for speed + sanity; falls back
  to a pure-Elixir scan using `Path.wildcard` + `File.read` when not.

  Arguments:

    * `pattern` (required) — regex.
    * `path_glob` (optional) — restrict the scan to files matching this glob.
    * `max_results` (optional, default 200) — cap on matching lines returned.
    * `include_artifacts` (optional, default false) — when true, also scans paths
      under `_build/`, `deps/`, `node_modules/`, `.git/`, `priv/static/`, `tmp/`.
  """

  @behaviour ExAthena.Tool

  @default_max 200
  @hard_cap 2_000

  @artifact_dirs ExAthena.Permissions.artifact_dirs()

  @impl true
  def name, do: "grep"

  @impl true
  def description,
    do:
      "Search file contents with a regex under the working directory. Optionally narrow by glob."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        pattern: %{type: "string"},
        path_glob: %{type: "string"},
        max_results: %{type: "integer"},
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
    glob = Map.get(args, "path_glob")
    include_artifacts = Map.get(args, "include_artifacts", false) == true

    case System.find_executable("rg") do
      nil -> elixir_grep(pattern, glob, cwd, max, include_artifacts)
      rg -> rg_grep(rg, pattern, glob, cwd, max, include_artifacts)
    end
  end

  def execute(_, _), do: {:error, :missing_pattern}

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @hard_cap)
  defp clamp(_), do: @default_max

  defp rg_grep(rg, pattern, glob, cwd, max, include_artifacts) do
    # Pass `.` explicitly — rg hangs on stdin when it can't detect a path arg
    # and runs under Port.
    base_args = ["--no-heading", "--line-number", "--max-count", to_string(max), pattern, "."]

    args =
      base_args
      |> maybe_prepend_glob(glob)
      |> prepend_artifact_excludes(include_artifacts)

    case System.cmd(rg, args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> build_payload(pattern, take_lines(output, max))
      # ripgrep exit 1 = no matches
      {"", 1} -> build_payload(pattern, [])
      {output, 1} -> build_payload(pattern, take_lines(output, max))
      {output, code} -> {:error, {:rg_failed, code, output}}
    end
  end

  defp build_payload(pattern, items) when is_list(items) do
    llm = if items == [], do: "(no matches)", else: Enum.join(items, "\n")

    ui = %{
      kind: :matches,
      payload: %{pattern: pattern, count: length(items), items: items}
    }

    {:ok, llm, ui}
  end

  defp maybe_prepend_glob(args, nil), do: args
  defp maybe_prepend_glob(args, glob), do: ["--glob", glob | args]

  defp prepend_artifact_excludes(args, true), do: args

  defp prepend_artifact_excludes(args, false) do
    # ripgrep glob semantics: `!dir/**` only matches at the search root, so
    # use `!**/dir/**` to also catch nested cases like `web/_build/...` in
    # Phoenix-in-subdir layouts.
    @artifact_dirs
    |> Enum.flat_map(fn dir ->
      bare = String.trim_trailing(dir, "/")
      ["--glob", "!**/#{bare}/**", "--glob", "!#{bare}/**"]
    end)
    |> Enum.concat(args)
  end

  defp elixir_grep(pattern, glob, cwd, max, include_artifacts) do
    with {:ok, regex} <- Regex.compile(pattern) do
      files =
        cwd
        |> Path.join(glob || "**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&artifact_path?(&1, cwd, include_artifacts))

      matches =
        files
        |> Stream.flat_map(fn path ->
          case File.read(path) do
            {:ok, body} -> scan_file(path, body, regex, cwd)
            _ -> []
          end
        end)
        |> Enum.take(max)

      build_payload(pattern, matches)
    else
      {:error, {msg, _offset}} -> {:error, {:invalid_regex, to_string(msg)}}
    end
  end

  defp artifact_path?(_path, _cwd, true), do: false

  defp artifact_path?(path, cwd, false) do
    rel = Path.relative_to(path, cwd)

    Enum.any?(@artifact_dirs, fn dir ->
      # Matches at root and nested (`web/_build/...`); see Glob for the rationale.
      String.starts_with?(rel, dir) or String.contains?(rel, "/" <> dir)
    end)
  end

  defp scan_file(path, body, regex, cwd) do
    rel = Path.relative_to(path, cwd)

    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      if Regex.match?(regex, line), do: ["#{rel}:#{idx}:#{line}"], else: []
    end)
  end

  defp take_lines(output, max) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(max)
  end
end
