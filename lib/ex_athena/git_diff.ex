defmodule ExAthena.GitDiff do
  @moduledoc """
  Single source of truth for the "all working-tree changes vs HEAD" diff that
  the chat UIs render (web Git tab + TUI Changes tab).

  `git diff HEAD` alone shows modified and **deleted** tracked files but NOT
  untracked (newly created) files. To make every change reviewable, this module
  appends a synthetic `new file` diff for each untracked, non-ignored file —
  capped so a generated/binary blob can't flood the pane.

  External `git` invocations are wrapped in `Task.async`/`yield` with a timeout
  (System.cmd has none) so a hung repo can never wedge the caller.
  """

  @timeout_ms 10_000

  # Per-file caps when synthesizing diffs for untracked files.
  @max_untracked_lines 500
  @max_untracked_bytes 100_000

  @type error :: :not_a_repo | :no_git | :timeout

  @doc """
  Build the combined unified diff (tracked changes vs HEAD + synthetic untracked
  files) for `cwd`.

  Returns `{:ok, ""}` when there are no changes, `{:ok, diff_text}` otherwise, or
  `{:error, reason}` for a non-repo / missing-git / git-failure.
  """
  @spec build(String.t()) :: {:ok, String.t()} | {:error, error()}
  def build(cwd) when is_binary(cwd) do
    case git(["rev-parse", "--show-toplevel"], cwd) do
      {:ok, _root} ->
        tracked =
          case git(["diff", "HEAD", "--color=never"], cwd) do
            {:ok, out} -> String.trim_trailing(out, "\n")
            _ -> ""
          end

        untracked = render_untracked_files(cwd)

        text =
          [tracked, untracked]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        {:ok, text}

      {:error, :no_git} ->
        {:error, :no_git}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        # `rev-parse` exits non-zero outside a work tree.
        {:error, :not_a_repo}
    end
  end

  # `git ls-files --others --exclude-standard` lists files that are neither
  # tracked nor gitignored. For each, synthesize a `--- /dev/null` / `+++ b/<p>`
  # diff so new files appear alongside tracked changes.
  defp render_untracked_files(cwd) do
    case git(["ls-files", "--others", "--exclude-standard"], cwd) do
      {:ok, out} ->
        out
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&render_untracked_file(&1, cwd))
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp render_untracked_file(rel, cwd) do
    header_base = [
      "diff --git a/#{rel} b/#{rel}",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/#{rel}"
    ]

    path = Path.join(cwd, rel)

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_untracked_bytes ->
        header_base ++ ["@@ -0,0 +1,1 @@", "+(file too large to show: #{size} bytes)"]

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} -> render_untracked_content(header_base, content)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp render_untracked_content(header_base, content) do
    if binary_content?(content) do
      header_base ++ ["@@ -0,0 +1,1 @@", "+(binary file)"]
    else
      lines = String.split(content, "\n")
      total = length(lines)
      visible = Enum.take(lines, @max_untracked_lines)
      shown = length(visible)
      diff_lines = Enum.map(visible, &("+" <> &1))

      footer = if total > shown, do: ["+… (#{total - shown} more lines)"], else: []

      hunk_header = "@@ -0,0 +1,#{shown + length(footer)} @@"
      header_base ++ [hunk_header] ++ diff_lines ++ footer
    end
  end

  # Cheap binary heuristic: a NUL byte in the first 1KB.
  defp binary_content?(""), do: false

  defp binary_content?(content) do
    head_size = min(byte_size(content), 1024)
    :binary.match(binary_part(content, 0, head_size), <<0>>) != :nomatch
  end

  # System.cmd has no timeout — wrap so a hung `git` can't wedge the caller.
  # The closure catches its own ErlangError (e.g. missing `git`) so the linked
  # Task never crashes us with an exit signal.
  defp git(args, cwd) do
    task =
      Task.async(fn ->
        try do
          {:ran, System.cmd("git", args, cd: cwd, stderr_to_stdout: true)}
        rescue
          e in ErlangError -> {:raised, e.original}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task) do
      {:ok, {:ran, {out, 0}}} -> {:ok, out}
      {:ok, {:ran, {out, _code}}} -> {:error, {:git, String.trim(out)}}
      {:ok, {:raised, :enoent}} -> {:error, :no_git}
      {:ok, {:raised, other}} -> {:error, {:git, inspect(other)}}
      _ -> {:error, :timeout}
    end
  end
end
