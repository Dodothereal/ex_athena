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
    "Summarize a file with a fast LLM call: returns purpose, key functions, " <>
      "types, and dependencies in ~10 lines without filling context with full file content. " <>
      "Call this before read on any file you have not seen yet in this session."
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

    prompt = """
    Summarize this source file in up to 10 concise lines.
    Cover: purpose of the file, key functions or modules defined,
    important types or data structures, and notable dependencies or imports.
    Return only the summary — no preamble, no code blocks.

    File: #{Path.basename(path)}

    #{truncated}
    """

    opts =
      [
        system_prompt: "You summarize source code files concisely. Return only the summary.",
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
