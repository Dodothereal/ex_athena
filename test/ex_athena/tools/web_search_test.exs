defmodule ExAthena.Tools.WebSearchTest do
  use ExUnit.Case, async: true

  import Mox

  alias ExAthena.Search.Result
  alias ExAthena.Tools.WebSearch
  alias ExAthena.ToolContext

  setup :verify_on_exit!

  defp ctx, do: ToolContext.new(cwd: "/tmp")

  test "is a registered builtin" do
    assert ExAthena.Tools.WebSearch in ExAthena.Tools.builtins()
  end

  test "calls the backend with the query + opts and formats results" do
    expect(ExAthena.Search.Mock, :search, fn "elixir genserver", opts ->
      assert opts[:max_results] == 3

      {:ok,
       [
         %Result{
           title: "GenServer",
           url: "https://hexdocs.pm/elixir/GenServer.html",
           snippet: "behaviour"
         },
         %Result{title: "OTP", url: "https://erlang.org/otp", snippet: "platform"}
       ]}
    end)

    assert {:ok, text, ui} =
             WebSearch.execute(%{"query" => "elixir genserver", "max_results" => 3}, ctx())

    assert text =~ "GenServer"
    assert text =~ "https://hexdocs.pm/elixir/GenServer.html"
    assert text =~ "behaviour"

    assert %{
             kind: :search_results,
             payload: %{query: "elixir genserver", count: 2, results: results}
           } = ui

    assert length(results) == 2
  end

  test "caps max_results at 20" do
    expect(ExAthena.Search.Mock, :search, fn _q, opts ->
      assert opts[:max_results] == 20
      {:ok, []}
    end)

    assert {:ok, _text, _ui} = WebSearch.execute(%{"query" => "q", "max_results" => 99}, ctx())
  end

  test "empty results return a friendly message, not an error" do
    expect(ExAthena.Search.Mock, :search, fn _q, _opts -> {:ok, []} end)

    assert {:ok, text, %{kind: :search_results, payload: %{count: 0}}} =
             WebSearch.execute(%{"query" => "nothing here"}, ctx())

    assert text =~ "No results"
  end

  test "missing/blank query is an error" do
    assert {:error, :missing_query} = WebSearch.execute(%{}, ctx())
    assert {:error, :missing_query} = WebSearch.execute(%{"query" => ""}, ctx())
  end

  test "no-api-key backend error surfaces a configuration message" do
    expect(ExAthena.Search.Mock, :search, fn _q, _opts -> {:error, :no_api_key} end)

    assert {:error, msg} = WebSearch.execute(%{"query" => "q"}, ctx())
    assert msg =~ "not configured"
  end

  test "http error from backend surfaces as an error string" do
    expect(ExAthena.Search.Mock, :search, fn _q, _opts -> {:error, {:http_error, 503}} end)

    assert {:error, msg} = WebSearch.execute(%{"query" => "q"}, ctx())
    assert msg =~ "web_search failed"
  end

  test "a hung backend is bounded by the tool timeout" do
    expect(ExAthena.Search.Mock, :search, fn _q, _opts ->
      Process.sleep(400)
      {:ok, []}
    end)

    assert {:error, msg} = WebSearch.execute(%{"query" => "q", "timeout_ms" => 20}, ctx())
    assert msg =~ "timed out"
  end
end
