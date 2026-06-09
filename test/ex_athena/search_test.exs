defmodule ExAthena.SearchTest do
  use ExUnit.Case, async: true

  alias ExAthena.Search
  alias ExAthena.Search.Result

  describe "impl/0" do
    test "defaults to the configured adapter (the Mox mock in test env)" do
      assert Search.impl() == ExAthena.Search.Mock
    end

    test "honors an explicit adapter override in app config" do
      prev = Application.get_env(:ex_athena, :search, [])
      on_exit(fn -> Application.put_env(:ex_athena, :search, prev) end)

      Application.put_env(:ex_athena, :search, adapter: ExAthena.Search.Http)
      assert Search.impl() == ExAthena.Search.Http
    end

    test "falls back to ExAthena.Search.Http when no adapter configured" do
      prev = Application.get_env(:ex_athena, :search, [])
      on_exit(fn -> Application.put_env(:ex_athena, :search, prev) end)

      Application.delete_env(:ex_athena, :search)
      assert Search.impl() == ExAthena.Search.Http
    end
  end

  describe "Result" do
    test "requires title and url" do
      assert %Result{title: "t", url: "http://x"} = %Result{title: "t", url: "http://x"}

      assert_raise ArgumentError, fn ->
        struct!(Result, snippet: "no keys")
      end
    end

    test "defaults snippet/score/published" do
      r = %Result{title: "t", url: "http://x"}
      assert r.snippet == ""
      assert r.score == nil
      assert r.published == nil
    end
  end

  describe "search/2 dispatch" do
    import Mox
    setup :verify_on_exit!

    test "delegates to the configured backend impl" do
      expect(ExAthena.Search.Mock, :search, fn "q", opts ->
        assert opts[:max_results] == 3
        {:ok, [%Result{title: "T", url: "http://x", snippet: "s"}]}
      end)

      assert {:ok, [%Result{url: "http://x"}]} = Search.search("q", max_results: 3)
    end
  end
end
