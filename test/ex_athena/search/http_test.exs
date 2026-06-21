defmodule ExAthena.Search.HttpTest do
  # async: false — these merge into the global :ex_athena/:search app env.
  use ExUnit.Case, async: false

  alias ExAthena.Search.Http
  alias ExAthena.Search.Result

  # Merge search config for one test (preserving the adapter set in test.exs so
  # concurrent tests that dispatch through ExAthena.Search are unaffected).
  defp put_search(extra) do
    prev = Application.get_env(:ex_athena, :search, [])
    on_exit(fn -> Application.put_env(:ex_athena, :search, prev) end)
    Application.put_env(:ex_athena, :search, Keyword.merge(prev, extra))
  end

  defp send_json(conn, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(map))
  end

  defp send_html(conn, html) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, html)
  end

  describe ":tavily backend" do
    test "POSTs query + api_key and maps results[].content -> snippet" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, conn.method, Jason.decode!(body)})

        send_json(conn, %{
          "results" => [
            %{
              "title" => "T1",
              "url" => "https://a.com",
              "content" => "snippet one",
              "score" => 0.9
            },
            %{"title" => "T2", "url" => "https://b.com", "content" => "snippet two"}
          ]
        })
      end

      put_search(backend: :tavily, api_key: "secret", req_options: [plug: plug])

      assert {:ok,
              [
                %Result{title: "T1", url: "https://a.com", snippet: "snippet one", score: 0.9},
                %Result{title: "T2"}
              ]} =
               Http.search("elixir", max_results: 5)

      assert_received {:req, "POST",
                       %{"query" => "elixir", "api_key" => "secret", "max_results" => 5}}
    end

    test "missing api_key returns {:error, :no_api_key} without calling out" do
      put_search(
        backend: :tavily,
        api_key: nil,
        req_options: [plug: fn _ -> raise "should not be called" end]
      )

      assert {:error, :no_api_key} = Http.search("q", [])
    end
  end

  describe ":brave backend" do
    test "sends x-subscription-token header and maps web.results" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:token, Plug.Conn.get_req_header(conn, "x-subscription-token")})

        send_json(conn, %{
          "web" => %{
            "results" => [%{"title" => "B1", "url" => "https://x.com", "description" => "desc"}]
          }
        })
      end

      put_search(backend: :brave, api_key: "brave-key", req_options: [plug: plug])

      assert {:ok, [%Result{title: "B1", url: "https://x.com", snippet: "desc"}]} =
               Http.search("q", max_results: 3)

      assert_received {:token, ["brave-key"]}
    end
  end

  describe ":searxng backend" do
    test "requires an endpoint" do
      put_search(backend: :searxng, endpoint: nil)
      assert {:error, {:request_failed, _}} = Http.search("q", [])
    end

    test "maps results[].content with a configured endpoint" do
      plug = fn conn ->
        send_json(conn, %{
          "results" => [%{"title" => "S1", "url" => "https://s.com", "content" => "c"}]
        })
      end

      put_search(backend: :searxng, endpoint: "http://localhost:8888", req_options: [plug: plug])

      assert {:ok, [%Result{title: "S1", url: "https://s.com", snippet: "c"}]} =
               Http.search("q", [])
    end

    test "requests JSON, maps score/published, and derives params from opts" do
      test_pid = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:get, conn.request_path, conn.params})

        send_json(conn, %{
          "results" => [
            %{
              "title" => "S1",
              "url" => "https://s.com",
              "content" => "c",
              "score" => 1.5,
              "publishedDate" => "2026-06-01"
            }
          ]
        })
      end

      # Trailing slash on the endpoint must not double up before "/search".
      put_search(backend: :searxng, endpoint: "http://localhost:8888/", req_options: [plug: plug])

      assert {:ok,
              [
                %Result{
                  title: "S1",
                  url: "https://s.com",
                  snippet: "c",
                  score: 1.5,
                  published: "2026-06-01"
                }
              ]} = Http.search("q", topic: "news", recency: "week")

      assert_received {:get, "/search", params}
      assert params["q"] == "q"
      assert params["format"] == "json"
      assert params["time_range"] == "week"
      assert params["categories"] == "news"
    end

    test "passes configured searxng options (language/safesearch/engines)" do
      test_pid = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.params})
        send_json(conn, %{"results" => []})
      end

      put_search(
        backend: :searxng,
        endpoint: "http://localhost:8888",
        searxng: [language: "en", safesearch: 1, engines: "google,duckduckgo"],
        req_options: [plug: plug]
      )

      assert {:ok, []} = Http.search("q", [])

      assert_received {:params, params}
      assert params["language"] == "en"
      assert params["safesearch"] == "1"
      assert params["engines"] == "google,duckduckgo"
      # General topic / no recency → those params are omitted entirely.
      refute Map.has_key?(params, "time_range")
      refute Map.has_key?(params, "categories")
    end
  end

  describe ":duckduckgo backend (default, HTML parse)" do
    @ddg_html """
    <html><body>
      <div class="result results_links web-result">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fhexdocs.pm%2Felixir%2FGenServer.html&rut=x">GenServer — Elixir</a>
        <a class="result__snippet">A behaviour module for implementing servers.</a>
      </div>
      <div class="result results_links web-result">
        <a class="result__a" href="https://erlang.org/doc">Erlang docs</a>
        <a class="result__snippet">OTP documentation.</a>
      </div>
    </body></html>
    """

    test "parses title, decoded url, and snippet from the SERP" do
      plug = fn conn -> send_html(conn, @ddg_html) end
      put_search(backend: :duckduckgo, req_options: [plug: plug])

      assert {:ok, results} = Http.search("elixir genserver", max_results: 5)

      assert [
               %Result{
                 title: "GenServer — Elixir",
                 url: "https://hexdocs.pm/elixir/GenServer.html",
                 snippet: "A behaviour module for implementing servers."
               },
               %Result{title: "Erlang docs", url: "https://erlang.org/doc"}
             ] = results
    end

    test "caps results to max_results" do
      plug = fn conn -> send_html(conn, @ddg_html) end
      put_search(backend: :duckduckgo, req_options: [plug: plug])

      assert {:ok, [%Result{}]} = Http.search("q", max_results: 1)
    end

    test "a 202 anomaly response is reported as blocked, not empty results" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 202, "<html>bot challenge</html>") end
      put_search(backend: :duckduckgo, req_options: [plug: plug])

      assert {:error, :blocked} = Http.search("q", [])
    end

    test "a 2xx CAPTCHA challenge body is reported as blocked" do
      body =
        "<html><body>Please complete the following challenge to confirm this search was made by a human.</body></html>"

      plug = fn conn -> send_html(conn, body) end
      put_search(backend: :duckduckgo, req_options: [plug: plug])

      assert {:error, :blocked} = Http.search("q", [])
    end
  end

  describe "errors" do
    test "non-2xx status -> {:error, {:http_error, status}}" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "nope") end
      put_search(backend: :searxng, endpoint: "http://localhost:8888", req_options: [plug: plug])
      assert {:error, {:http_error, 503}} = Http.search("q", [])
    end

    test "unsupported backend -> {:error, {:unsupported_backend, _}}" do
      put_search(backend: :nope)
      assert {:error, {:unsupported_backend, :nope}} = Http.search("q", [])
    end
  end
end
