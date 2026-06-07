defmodule ExAthena.Tools.Read do
  @moduledoc """
  Reads a file from the filesystem.

  Arguments:

    * `path` (required) — absolute path or a path relative to `ctx.cwd`.
    * `offset` (optional) — line number to start reading from (1-indexed).
    * `limit` (optional) — maximum number of lines to return.

  Result is the file contents with lines prefixed by `<lineno>\\t` so the model
  can reference specific lines the way Claude Code does.

  Oversized output never floods the context: a whole-file read of a large
  structured file returns a line-ranged OUTLINE ("lines 12–80: def foo")
  the model can drill into via offset/limit; unstructured files and huge
  explicit windows are head-capped with an explicit marker.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.ToolContext

  @max_bytes 2_000_000
  # Same context-protection budget as bash output.
  @max_output_chars 16_000
  @head_chars 12_000
  @max_outline_entries 150

  # Structural anchors for the outline — language-generic top-level
  # constructs (Elixir, JS/TS, Python, Ruby, markdown headers).
  @anchor_re ~r/^(defmodule|defprotocol|defimpl|\s{0,2}(def|defp|defmacro|describe|test|setup)\b|\s*(class|function|interface|module|const\s+\w+\s*=|export)\b|\#{1,3}\s)/

  @impl true
  def name, do: "read"

  @impl true
  def description,
    do: "Read a file from the filesystem, optionally starting at a line offset with a line limit."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "absolute or cwd-relative path"},
        offset: %{type: "integer", description: "1-indexed line to start from"},
        limit: %{type: "integer", description: "max lines to return"}
      },
      required: ["path"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(args, %ToolContext{} = ctx) do
    with {:ok, path} <- fetch_path(args, ctx),
         {:ok, stat} <- File.stat(path),
         :ok <- check_size(stat),
         :ok <- check_regular(stat),
         {:ok, body} <- File.read(path) do
      formatted = body |> format(args) |> guard_output(body, args)

      offset = Map.get(args, "offset")
      limit = Map.get(args, "limit")

      ui = %{
        kind: :file,
        payload: %{
          path: path,
          content: body,
          line_range: line_range(body, offset, limit)
        }
      }

      {:ok, formatted, ui}
    end
  end

  # Keep oversized reads from flooding the context. Whole-file reads of
  # structured files become a line-ranged outline; everything else is
  # head-capped with an explicit re-read hint.
  defp guard_output(formatted, body, args) when byte_size(formatted) > @max_output_chars do
    explicit_window? = Map.get(args, "offset") != nil or Map.get(args, "limit") != nil

    case if(explicit_window?, do: nil, else: outline(body)) do
      nil ->
        total = body |> String.split("\n") |> length()

        String.slice(formatted, 0, @head_chars) <>
          "\n…[truncated — file has #{total} lines; re-read with offset/limit for the rest]…"

      outline ->
        outline
    end
  end

  defp guard_output(formatted, _body, _args), do: formatted

  # Line-ranged structural outline: "lines 12–80: def foo(bar)". Returns
  # nil when the file has too little structure to outline usefully.
  defp outline(body) do
    lines = String.split(body, "\n")
    total = length(lines)

    anchors =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(@anchor_re, line) end)

    if length(anchors) < 3 do
      nil
    else
      anchors = Enum.take(anchors, @max_outline_entries)

      entries =
        anchors
        |> Enum.chunk_every(2, 1)
        |> Enum.map_join("\n", fn
          [{line, n}, {_next, next_n}] -> "lines #{n}–#{next_n - 1}: #{anchor_label(line)}"
          [{line, n}] -> "lines #{n}–#{total}: #{anchor_label(line)}"
        end)

      capped_note =
        if length(anchors) == @max_outline_entries,
          do: "\n…[outline capped at #{@max_outline_entries} entries]…",
          else: ""

      "[file too large to return whole: #{total} lines — outline below; " <>
        "re-read with offset/limit for specific ranges]\n" <> entries <> capped_note
    end
  end

  defp anchor_label(line) do
    line |> String.trim() |> String.slice(0, 80)
  end

  defp line_range(_body, nil, nil), do: nil

  defp line_range(body, offset, limit) do
    total = body |> String.split("\n") |> length()
    start_line = max(offset || 1, 1)
    take = limit || max(total - start_line + 1, 0)
    end_line = min(start_line + take - 1, total)
    {start_line, end_line}
  end

  defp fetch_path(%{"path" => path}, ctx) when is_binary(path) do
    # An empty or whitespace-only path used to resolve to `cwd` (then on
    # some filesystems return the contents of the first regular file —
    # typically README). Reject explicitly so the model gets a clear
    # `:missing_path` signal instead of `:not_a_regular_file` or a
    # confusing partial read of the wrong file.
    case String.trim(path) do
      "" -> {:error, :missing_path}
      trimmed -> ToolContext.resolve_path(ctx, trimmed)
    end
  end

  defp fetch_path(_, _), do: {:error, :missing_path}

  defp check_size(%File.Stat{size: size}) when size > @max_bytes,
    do: {:error, {:file_too_large, size}}

  defp check_size(_), do: :ok

  defp check_regular(%File.Stat{type: :regular}), do: :ok
  defp check_regular(%File.Stat{type: type}), do: {:error, {:not_a_regular_file, type}}

  defp format(body, args) do
    # Number from the file's REAL line, not 1 — otherwise offset reads
    # mislabel every line and the model cites wrong locations.
    start_line =
      case Map.get(args, "offset") do
        o when is_integer(o) and o > 0 -> o
        _ -> 1
      end

    body
    |> String.split("\n")
    |> slice(args)
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, idx} -> "#{idx}\t#{line}" end)
  end

  defp slice(lines, args) do
    offset = Map.get(args, "offset")
    limit = Map.get(args, "limit")

    lines =
      case offset do
        nil -> lines
        0 -> lines
        o when is_integer(o) and o > 0 -> Enum.drop(lines, o - 1)
        _ -> lines
      end

    case limit do
      nil -> lines
      l when is_integer(l) and l > 0 -> Enum.take(lines, l)
      _ -> lines
    end
  end
end
