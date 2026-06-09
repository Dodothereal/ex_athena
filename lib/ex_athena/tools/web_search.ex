defmodule ExAthena.Tools.WebSearch do
  @moduledoc """
  Search the web and return ranked results (title, url, snippet).

  Use this to *discover* sources, then `web_fetch` the most relevant URL to read
  it in full. The search backend (DuckDuckGo / Tavily / Brave / SearXNG) is
  chosen by the host via `config :ex_athena, :search` — the agent never picks a
  provider. All backend access goes through the `ExAthena.Search` behaviour, so
  this tool never talks to an HTTP client directly.

  Arguments:

    * `query` (required) — the search query.
    * `max_results` (optional, default #{5}, capped at 20).
    * `topic` (optional, `"general"` | `"news"`).
    * `recency` (optional, e.g. `"week"`, `"month"`).
    * `timeout_ms` (optional, default 10_000).
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Search

  @default_max_results 5
  @max_results_cap 20
  @default_timeout 10_000
  @max_snippet_chars 500
  # Grace over the configured timeout for the outer Task.yield backstop: long
  # enough for the adapter's own (receive_timeout-bounded) error tuple to
  # propagate back, short enough that a hung adapter is killed promptly.
  @timeout_grace_ms 250

  @impl true
  def name, do: "web_search"

  @impl true
  def description,
    do:
      "Search the web and return ranked results (title, url, snippet). " <>
        "Use this to discover URLs, then web_fetch to read one in full."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "The search query."},
        max_results: %{
          type: "integer",
          description: "Max results (default #{@default_max_results}, cap #{@max_results_cap})."
        },
        topic: %{type: "string", enum: ["general", "news"], description: "Optional search topic."},
        recency: %{
          type: "string",
          description: "Optional recency hint, e.g. \"week\", \"month\"."
        },
        timeout_ms: %{
          type: "integer",
          description: "Request timeout (default #{@default_timeout})."
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(%{"query" => query} = args, _ctx) when is_binary(query) and query != "" do
    timeout = Map.get(args, "timeout_ms", @default_timeout)

    opts =
      [
        max_results:
          args |> Map.get("max_results", @default_max_results) |> min(@max_results_cap),
        timeout_ms: timeout
      ]
      |> maybe_put(:topic, Map.get(args, "topic"))
      |> maybe_put(:recency, Map.get(args, "recency"))

    case run_with_timeout(query, opts, timeout) do
      {:ok, results} ->
        ui = %{
          kind: :search_results,
          payload: %{
            query: query,
            count: length(results),
            results: Enum.map(results, &Map.take(&1, [:title, :url, :snippet]))
          }
        }

        {:ok, format(results, query), ui}

      {:error, :no_api_key} ->
        {:error, "web_search backend is not configured (missing API key or endpoint)"}

      {:error, :timeout} ->
        {:error, "web_search timed out after #{timeout}ms"}

      {:error, reason} ->
        {:error, "web_search failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, :missing_query}

  # External calls need a hard ceiling. Run the backend in a Task and yield with
  # a small grace over the configured timeout so a hung adapter (or one that
  # ignores its own receive_timeout) can never wedge the agent loop.
  defp run_with_timeout(query, opts, timeout) do
    task = Task.async(fn -> Search.search(query, opts) end)

    case Task.yield(task, timeout + @timeout_grace_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp format([], query), do: "No results for #{inspect(query)}."

  defp format(results, _query) do
    results
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {r, i} ->
      snippet = r.snippet |> to_string() |> String.slice(0, @max_snippet_chars)
      "#{i}. #{r.title}\n   #{r.url}\n   #{snippet}"
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
