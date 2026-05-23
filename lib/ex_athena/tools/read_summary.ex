defmodule ExAthena.Tools.ReadSummary do
  @moduledoc """
  Summarizes a file using a single LLM call, returning purpose, key
  functions, types, and dependencies in ~10 lines without loading the
  full content into the main conversation context.

  The summarizer provider is drawn from `ctx.assigns[:summarizer_opts]`
  (a keyword list forwarded to `ExAthena.query/2`). When absent, falls
  back to ex_athena's default configured provider.

  Consumers should call this before `read` on any unfamiliar file. Only
  use `read` (with `offset` and `limit`) after this, and only for the
  specific sections that require full detail.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.ToolContext

  @max_input_bytes 12_000

  @impl true
  def name, do: "read_summary"

  @impl true
  def description do
    "Default tool for any file you have not yet read in this conversation. " <>
      "Runs a one-off LLM call and returns a structured summary: purpose, key " <>
      "functions/modules with approximate line numbers, important types, and notable " <>
      "imports — without loading the full file into context. " <>
      "Always call this first; only call read afterwards, and only for the specific " <>
      "line ranges this summary identifies."
  end

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "absolute or cwd-relative path to the file"}
      },
      required: ["path"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(%{"path" => path}, %ToolContext{} = ctx) when is_binary(path) do
    case String.trim(path) do
      "" ->
        {:error, "path is required"}

      trimmed ->
        with {:ok, resolved} <- ToolContext.resolve_path(ctx, trimmed),
             {:ok, content} <- File.read(resolved) do
          provider_opts =
            ctx.assigns
            |> Map.get(:spawn_agent_opts, [])
            |> Keyword.take([:provider, :model, :api_key, :base_url])

          summarize(resolved, content, provider_opts)
        end
    end
  end

  def execute(_args, _ctx), do: {:error, "path is required"}

  defp summarize(path, content, provider_opts) do
    truncated = String.slice(content, 0, @max_input_bytes)
    total_lines = content |> String.split("\n") |> length()

    prompt = """
    You are summarizing a source file so an AI agent can decide which specific lines to read next.
    Be precise and actionable. Respond with this exact structure — no preamble, no code fences:

    Purpose: <one sentence describing what this file does>
    Key definitions: <name> ~L<line> — <one-phrase description>; one entry per line
    Types/structs: <name> ~L<line> — <one-phrase description>; one entry per line (or "none")
    Dependencies: <comma-separated notable imports or external modules>
    Notes: <surprising constraints, invariants, or patterns a reader should know> (or "none")

    Approximate line numbers are critical — they let the agent call `read` with the right
    offset and limit instead of reading the whole file. Include them for every definition.

    File: #{Path.basename(path)} (#{total_lines} lines total)

    #{truncated}
    """

    opts =
      [
        system_prompt:
          "You summarize source code files into structured, line-number-anchored summaries. " <>
            "Return only the summary in the requested format.",
        allowed_tools: []
      ] ++ provider_opts

    case ExAthena.query(prompt, opts) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        {:ok, "[Summary: #{path}]\n#{String.trim(text)}"}

      {:ok, _} ->
        {:error, "summarizer returned empty response"}

      {:error, reason} ->
        {:error, "summarizer failed: #{inspect(reason)}"}
    end
  end
end
