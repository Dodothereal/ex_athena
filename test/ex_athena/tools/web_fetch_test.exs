defmodule ExAthena.Tools.WebFetchTest do
  @moduledoc """
  Overflow handling for fetched pages — a 1MB raw HTML dump used to flood a
  9B worker's context (observed live: stream timeouts + starved workers).
  Oversized content is either SUMMARIZED by a tool-less model call (when
  summarizer config is available) or explicitly truncated.
  """
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.WebFetch

  describe "handle_body/3 (post-fetch overflow handling, no network)" do
    test "small bodies pass through untouched" do
      ctx = ToolContext.new(cwd: ".")
      assert {"hello", false} = WebFetch.handle_body("hello", %{}, ctx)
    end

    test "oversized bodies are truncated with an explicit marker when no summarizer exists" do
      ctx = ToolContext.new(cwd: ".")
      big = String.duplicate("x", 30_000)

      {body, truncated?} = WebFetch.handle_body(big, %{}, ctx)

      assert truncated?
      assert String.length(body) < 21_000
      assert body =~ "truncated"
    end

    test "max_chars arg controls the cap" do
      ctx = ToolContext.new(cwd: ".")
      big = String.duplicate("x", 9_000)

      {body, truncated?} = WebFetch.handle_body(big, %{"max_chars" => 1_000}, ctx)

      assert truncated?
      assert String.length(body) < 1_200
    end

    test "oversized bodies are SUMMARIZED via a tool-less model call when configured" do
      ctx =
        ToolContext.new(
          cwd: ".",
          assigns: %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [text: "FACT: nimble does X"],
              memory: false
            ]
          }
        )

      big = String.duplicate("words about nimble publisher ", 2_000)

      {body, truncated?} =
        WebFetch.handle_body(big, %{"query" => "how is nimble used"}, ctx)

      assert truncated?
      assert body =~ "FACT: nimble does X"
      assert body =~ "summarized"
    end
  end

  describe "SSRF guard" do
    test "a confined run blocks a loopback/private host before fetching" do
      ctx = ToolContext.new(cwd: ".", allowed_roots: ["."])

      assert {:error, {:blocked_host, "localhost"}} =
               WebFetch.execute(%{"url" => "http://localhost:5432/"}, ctx)

      assert {:error, {:blocked_host, "169.254.169.254"}} =
               WebFetch.execute(%{"url" => "http://169.254.169.254/latest/meta-data/"}, ctx)
    end

    test "an UNCONFINED run blocks loopback/private hosts too (default-deny)" do
      ctx = ToolContext.new(cwd: ".")

      assert {:error, {:blocked_host, "localhost"}} =
               WebFetch.execute(%{"url" => "http://localhost:5432/"}, ctx)

      assert {:error, {:blocked_host, "169.254.169.254"}} =
               WebFetch.execute(%{"url" => "http://169.254.169.254/latest/meta-data/"}, ctx)

      assert {:error, {:blocked_host, "10.0.0.7"}} =
               WebFetch.execute(%{"url" => "http://10.0.0.7/admin"}, ctx)
    end

    test "allow_local_hosts: true opts out of the block for local development" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/doc", fn conn ->
        Plug.Conn.resp(conn, 200, "local page")
      end)

      ctx = ToolContext.new(cwd: ".", assigns: %{allow_local_hosts: true})

      assert {:ok, "local page", %{kind: :webpage, payload: %{status: 200}}} =
               WebFetch.execute(%{"url" => "http://localhost:#{bypass.port}/doc"}, ctx)
    end

    test "non-http schemes are rejected regardless of confinement" do
      ctx = ToolContext.new(cwd: ".")

      assert {:error, {:invalid_scheme, "file"}} =
               WebFetch.execute(%{"url" => "file:///etc/passwd"}, ctx)
    end
  end

  describe "redirects (every hop re-validated)" do
    setup do
      %{
        bypass: Bypass.open(),
        ctx: ToolContext.new(cwd: ".", assigns: %{allow_local_hosts: true})
      }
    end

    test "follows a chain of allowed redirect targets (relative and absolute)",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/a", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/b")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(bypass, "GET", "/b", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{bypass.port}/c")
        |> Plug.Conn.resp(301, "")
      end)

      Bypass.expect_once(bypass, "GET", "/c", fn conn ->
        Plug.Conn.resp(conn, 200, "final page")
      end)

      assert {:ok, "final page", %{payload: %{status: 200}}} =
               WebFetch.execute(%{"url" => "http://localhost:#{bypass.port}/a"}, ctx)
    end

    test "a redirect to a non-http scheme is denied", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/a", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "ftp://198.51.100.7/secrets")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, {:invalid_scheme, "ftp"}} =
               WebFetch.execute(%{"url" => "http://localhost:#{bypass.port}/a"}, ctx)
    end

    test "redirect targets pass the exact same validation as the initial URL" do
      # Every hop goes through validate_target/2 — a public 302 to the cloud
      # metadata endpoint or an internal service is refused mid-chain.
      ctx = ToolContext.new(cwd: ".")

      assert {:error, {:blocked_host, "169.254.169.254"}} =
               WebFetch.validate_target(URI.parse("http://169.254.169.254/latest"), ctx)

      assert {:error, {:blocked_host, "10.1.2.3"}} =
               WebFetch.validate_target(URI.parse("https://10.1.2.3/internal"), ctx)

      assert {:error, :missing_host} = WebFetch.validate_target(URI.parse("http://"), ctx)

      allowed_ctx = ToolContext.new(cwd: ".", assigns: %{allow_local_hosts: true})

      assert {:ok, %URI{host: "localhost"}} =
               WebFetch.validate_target(URI.parse("http://localhost:4000/x"), allowed_ctx)
    end

    test "a redirect loop stops at the hop cap", %{bypass: bypass, ctx: ctx} do
      Bypass.expect(bypass, "GET", "/loop", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/loop")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, :too_many_redirects} =
               WebFetch.execute(%{"url" => "http://localhost:#{bypass.port}/loop"}, ctx)
    end

    test "a redirect without a Location header is an HTTP error", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/nowhere", fn conn ->
        Plug.Conn.resp(conn, 302, "")
      end)

      assert {:error, {:http_error, 302}} =
               WebFetch.execute(%{"url" => "http://localhost:#{bypass.port}/nowhere"}, ctx)
    end
  end
end
