defmodule ExAthena.Search.Http do
  @moduledoc """
  HTTP-backed `ExAthena.Search` implementation. Backend-agnostic: the actual
  provider is chosen by config and is the *only* provider-specific code here.

      config :ex_athena, :search,
        adapter: ExAthena.Search.Http,
        backend: :duckduckgo,           # :duckduckgo | :tavily | :brave | :searxng
        api_key: System.get_env("EX_ATHENA_SEARCH_API_KEY"),
        endpoint: System.get_env("EX_ATHENA_SEARCH_ENDPOINT")

  | backend       | auth                | extra config        | notes |
  |----------------|---------------------|---------------------|-------|
  | `:duckduckgo`  | none                | —                   | default; parses the HTML SERP — best-effort, rate-limited, no official API |
  | `:tavily`      | `api_key` (paid)    | —                   | clean LLM-oriented snippets |
  | `:brave`       | `api_key` (free tier)| —                  | privacy-focused |
  | `:searxng`     | none                | `endpoint` required | self-hosted |

  Tests inject a `plug` (or any Req option) via `config :ex_athena, :search,
  req_options: [...]` so no network is hit.
  """

  @behaviour ExAthena.Search

  alias ExAthena.Search.Result

  @default_max_results 5
  @default_timeout 10_000
  @user_agent "ExAthena/1.0 (+https://github.com/; web_search tool)"

  @impl true
  def search(query, opts) when is_binary(query) do
    cfg = Application.get_env(:ex_athena, :search, [])
    backend = Keyword.get(cfg, :backend, :duckduckgo)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    max = opts |> Keyword.get(:max_results, @default_max_results) |> max(1)

    with {:ok, req_opts} <- build_request(backend, query, max, opts, cfg) do
      case run(backend, req_opts, timeout, cfg) do
        {:ok, results} -> {:ok, Enum.take(results, max)}
        {:error, _} = err -> err
      end
    end
  end

  # ── per-backend request construction (the only provider-specific code) ──

  defp build_request(:duckduckgo, query, _max, _opts, cfg) do
    base = cfg[:endpoint] || "https://html.duckduckgo.com"

    {:ok,
     [
       method: :get,
       url: base <> "/html/",
       params: [q: query],
       decode_body: false,
       headers: [{"user-agent", @user_agent}]
     ]}
  end

  defp build_request(:tavily, query, max, opts, cfg) do
    case cfg[:api_key] do
      key when is_binary(key) and key != "" ->
        {:ok,
         [
           method: :post,
           url: (cfg[:endpoint] || "https://api.tavily.com") <> "/search",
           json: %{
             api_key: key,
             query: query,
             max_results: max,
             topic: Keyword.get(opts, :topic, "general"),
             search_depth: "basic"
           }
         ]}

      _ ->
        {:error, :no_api_key}
    end
  end

  defp build_request(:brave, query, max, _opts, cfg) do
    case cfg[:api_key] do
      key when is_binary(key) and key != "" ->
        {:ok,
         [
           method: :get,
           url: (cfg[:endpoint] || "https://api.search.brave.com/res/v1") <> "/web/search",
           params: [q: query, count: max],
           headers: [{"x-subscription-token", key}, {"accept", "application/json"}]
         ]}

      _ ->
        {:error, :no_api_key}
    end
  end

  defp build_request(:searxng, query, _max, _opts, cfg) do
    case cfg[:endpoint] do
      url when is_binary(url) and url != "" ->
        {:ok, [method: :get, url: url <> "/search", params: [q: query, format: "json"]]}

      _ ->
        {:error, {:request_failed, "searxng backend requires :endpoint config"}}
    end
  end

  defp build_request(other, _query, _max, _opts, _cfg),
    do: {:error, {:unsupported_backend, other}}

  defp run(backend, req_opts, timeout, cfg) do
    base = [receive_timeout: timeout, retry: false] ++ req_opts ++ (cfg[:req_options] || [])

    case Req.request(base) do
      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        {:ok, normalize(backend, body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} when is_exception(exception) ->
        {:error, {:request_failed, Exception.message(exception)}}

      {:error, reason} ->
        {:error, {:request_failed, inspect(reason)}}
    end
  end

  # ── per-backend response → [Result.t()] mapping ──

  defp normalize(:tavily, %{"results" => rs}) when is_list(rs) do
    Enum.map(rs, fn r ->
      %Result{title: r["title"], url: r["url"], snippet: r["content"] || "", score: r["score"]}
    end)
  end

  defp normalize(:brave, %{"web" => %{"results" => rs}}) when is_list(rs) do
    Enum.map(rs, fn r ->
      %Result{title: r["title"], url: r["url"], snippet: r["description"] || ""}
    end)
  end

  defp normalize(:searxng, %{"results" => rs}) when is_list(rs) do
    Enum.map(rs, fn r ->
      %Result{title: r["title"], url: r["url"], snippet: r["content"] || ""}
    end)
  end

  defp normalize(:duckduckgo, html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> parse_ddg(doc)
      _ -> []
    end
  end

  defp normalize(_backend, _body), do: []

  # DDG HTML SERP: each result row carries a `.result__a` anchor (title + a
  # redirect href) and a `.result__snippet`. Best-effort — markup may shift.
  defp parse_ddg(doc) do
    doc
    |> Floki.find(".result")
    |> Enum.flat_map(fn result ->
      case Floki.find(result, "a.result__a") do
        [anchor | _] ->
          title = anchor |> Floki.text() |> String.trim()
          href = anchor |> Floki.attribute("href") |> List.first() |> to_string()
          snippet = result |> Floki.find(".result__snippet") |> Floki.text() |> String.trim()

          if title == "" or href == "",
            do: [],
            else: [%Result{title: title, url: clean_url(href), snippet: snippet}]

        [] ->
          []
      end
    end)
  end

  # DDG wraps result links in a redirect: //duckduckgo.com/l/?uddg=<encoded>&...
  defp clean_url("//duckduckgo.com/l/?" <> qs), do: extract_uddg(qs)
  defp clean_url("https://duckduckgo.com/l/?" <> qs), do: extract_uddg(qs)
  defp clean_url(url), do: url

  defp extract_uddg(qs) do
    case URI.decode_query(qs) do
      %{"uddg" => target} when is_binary(target) -> target
      _ -> qs
    end
  end
end
