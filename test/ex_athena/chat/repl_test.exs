defmodule ExAthena.Chat.ReplTest do
  use ExUnit.Case, async: false

  alias ExAthena.Chat.{Repl, Session}

  setup do
    original = Application.get_env(:ex_athena, :ollama)

    on_exit(fn ->
      if original do
        Application.put_env(:ex_athena, :ollama, original)
      else
        Application.delete_env(:ex_athena, :ollama)
      end
    end)

    :ok
  end

  describe "select_initial_model/2" do
    test "keeps the desired model when it is in the installed list" do
      assert Repl.select_initial_model("llama3.1", {:ok, ["llama3.1", "qwen2.5"]}) ==
               {:ok, "llama3.1"}
    end

    test "falls back to the first installed model when the desired one is missing" do
      assert Repl.select_initial_model("llama3.1", {:ok, ["qwen2.5", "mistral"]}) ==
               {:fallback, "qwen2.5"}
    end

    test "reports :no_models when Ollama has none installed" do
      assert Repl.select_initial_model("anything", {:ok, []}) == {:error, :no_models}
    end

    test "passes through the underlying error when the list lookup failed" do
      assert Repl.select_initial_model("anything", {:error, :ollama_unreachable}) ==
               {:error, :ollama_unreachable}

      assert Repl.select_initial_model("anything", {:error, {:http, 500}}) ==
               {:error, {:http, 500}}
    end
  end

  describe "build_run_opts/2" do
    test "adds a localhost Ollama base_url when nothing is configured" do
      Application.delete_env(:ex_athena, :ollama)

      session = Session.new(model: "qwen2.5")
      opts = Repl.build_run_opts(session, fn _ -> :ok end)

      assert opts[:provider] == :ollama
      assert opts[:model] == "qwen2.5"
      assert opts[:mode] == :react
      assert opts[:base_url] == "http://localhost:11434"
      assert is_function(opts[:on_event], 1)
    end

    test "sets timeout_ms: :infinity so a thinking model never trips the default 60s timeout" do
      Application.delete_env(:ex_athena, :ollama)

      session = Session.new(model: "any")
      opts = Repl.build_run_opts(session, fn _ -> :ok end)

      assert opts[:timeout_ms] == :infinity
    end

    test "omits :base_url when the user has configured one in app env" do
      Application.put_env(:ex_athena, :ollama,
        base_url: "http://my-ollama.lan:11434",
        model: "llama3.1"
      )

      session = Session.new([])
      opts = Repl.build_run_opts(session, fn _ -> :ok end)

      # Don't override the user's config — Loop reads it via Config.provider_opts/2.
      refute Keyword.has_key?(opts, :base_url)
    end
  end
end
