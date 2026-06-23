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

  describe "SSRF guard (confined runs only, no network)" do
    test "a confined run blocks a loopback/private host before fetching" do
      ctx = ToolContext.new(cwd: ".", allowed_roots: ["."])

      assert {:error, {:blocked_host, "localhost"}} =
               WebFetch.execute(%{"url" => "http://localhost:5432/"}, ctx)

      assert {:error, {:blocked_host, "169.254.169.254"}} =
               WebFetch.execute(%{"url" => "http://169.254.169.254/latest/meta-data/"}, ctx)
    end

    test "non-http schemes are rejected regardless of confinement" do
      ctx = ToolContext.new(cwd: ".")

      assert {:error, {:invalid_scheme, "file"}} =
               WebFetch.execute(%{"url" => "file:///etc/passwd"}, ctx)
    end
  end
end
