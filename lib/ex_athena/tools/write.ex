defmodule ExAthena.Tools.Write do
  @moduledoc """
  Creates or overwrites a file with the given content.

  Arguments:

    * `path` (required) — absolute or cwd-relative path.
    * `content` (required) — file body, UTF-8 string.

  Parent directories are created automatically. If the file already exists it
  is overwritten — that matches `File.write!/2` semantics. Use `Edit` when
  you want to mutate a subset of the file.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.ToolContext

  @impl true
  def name, do: "write"

  @impl true
  def description,
    do: "Create or overwrite a file. Parent directories are created automatically."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        content: %{type: "string"}
      },
      required: ["path", "content"]
    }
  end

  @impl true
  def execute(args, %ToolContext{} = ctx) do
    with {:ok, path} <- fetch_path(args, ctx),
         {:ok, content} <- fetch_content(args),
         :ok <- File.mkdir_p(Path.dirname(path)),
         _ <- maybe_snapshot(ctx, path),
         before = read_existing(path),
         :ok <- File.write(path, content) do
      llm = "wrote #{byte_size(content)} bytes to #{Path.relative_to(path, ctx.cwd)}"

      ui = %{
        kind: :diff,
        payload: %{
          path: path,
          before: before,
          after: content,
          replacements: nil
        }
      }

      {:ok, llm, ui}
    end
  end

  # `""` for new files so the TUI's diff renderer treats the entire new
  # content as added lines (Myers diff over [""] vs split(content) yields
  # all `:ins`). Errors (permission denied, etc.) also map to `""` — the
  # write itself either succeeded with that prior state or hasn't run yet.
  defp read_existing(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  # Best-effort: snapshot the prior contents (or tombstone for new files)
  # so `ExAthena.Checkpoint.rewind/3` can restore. Always runs before
  # mutation; failures are silently swallowed (the snapshot is a safety
  # net, not a correctness contract).
  defp maybe_snapshot(%ToolContext{session_id: sid, cwd: cwd}, path)
       when is_binary(sid) and sid != "" do
    _ = ExAthena.Checkpoint.snapshot(cwd, sid, path)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_snapshot(_, _), do: :ok

  defp fetch_path(%{"path" => path}, ctx), do: ToolContext.resolve_path(ctx, path)
  defp fetch_path(_, _), do: {:error, :missing_path}

  defp fetch_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp fetch_content(_), do: {:error, :missing_content}
end
