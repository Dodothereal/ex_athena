defmodule ExAthena.Providers.ReqLLMOpenRouterTest do
  @moduledoc """
  Integration test: verifies that an openrouter.json ProviderSpec resolves end-to-end
  through Config.pop_provider!/1 and ReqLLM.build_opts/2 with all spec fields wired
  correctly (module, req_llm_provider_tag, base_url, api_key, extra_headers).
  """

  use ExUnit.Case, async: false

  alias ExAthena.{Config, Request}
  alias ExAthena.Providers.ReqLLM, as: Adapter

  @env_var "EX_ATHENA_TEST_OPENROUTER_KEY_#{System.unique_integer([:positive])}"

  setup_all do
    System.put_env(@env_var, "sk-or-test-abc123")
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  setup do
    dir = tmp_dir_create()

    write_json(dir, "openrouter.json", %{
      name: "openrouter",
      adapter: "req_llm",
      req_llm_provider_tag: "openrouter",
      base_url: "https://openrouter.ai/api/v1",
      api_key_env: @env_var,
      extra_headers: %{
        "HTTP-Referer" => "https://myapp.io",
        "X-Title" => "MyApp"
      }
    })

    start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})
    :ok
  end

  describe "openrouter spec resolves correctly through Config.pop_provider!/1" do
    test "resolves provider atom to ExAthena.Providers.ReqLLM" do
      {mod, _opts} = Config.pop_provider!(provider: :openrouter)
      assert mod == ExAthena.Providers.ReqLLM
    end

    test "threads req_llm_provider_tag from spec" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter)
      assert opts[:req_llm_provider_tag] == "openrouter"
    end

    test "threads base_url from spec" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter)
      assert opts[:base_url] == "https://openrouter.ai/api/v1"
    end

    test "resolves api_key from api_key_env" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter)
      assert opts[:api_key] == "sk-or-test-abc123"
    end

    test "threads extra_headers from spec" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter)

      assert opts[:extra_headers] == %{
               "HTTP-Referer" => "https://myapp.io",
               "X-Title" => "MyApp"
             }
    end
  end

  describe "extra_headers fold through build_opts" do
    test "extra_headers appear in req_http_options after build_opts" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter, model: "openai/gpt-4o")
      request = %Request{messages: []}

      {:ok, built_opts} = Adapter.build_opts(request, opts)

      http_opts = Keyword.get(built_opts, :req_http_options, [])
      headers = Keyword.get(http_opts, :headers, [])

      assert {"HTTP-Referer", "https://myapp.io"} in headers
      assert {"X-Title", "MyApp"} in headers
    end

    test "api_key is present in built_opts" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter, model: "openai/gpt-4o")
      request = %Request{messages: []}

      {:ok, built_opts} = Adapter.build_opts(request, opts)

      assert built_opts[:api_key] == "sk-or-test-abc123"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp tmp_dir_create do
    dir = Path.join(System.tmp_dir!(), "ex_athena_or_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_json(dir, filename, data) do
    File.write!(Path.join(dir, filename), Jason.encode!(data))
  end
end
