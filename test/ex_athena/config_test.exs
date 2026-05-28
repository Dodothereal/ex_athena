defmodule ExAthena.ConfigTest do
  use ExUnit.Case, async: false

  alias ExAthena.Config

  @all_provider_atoms [
    :ollama,
    :openai,
    :openai_compatible,
    :llamacpp,
    :claude,
    :anthropic,
    :req_llm,
    :gemini,
    :openrouter
  ]

  setup do
    # Clear any env leaked by Igniter-based tests (install task) that temporarily
    # mutate Application env while writing config files.
    for atom <- [:default_provider, :model | @all_provider_atoms],
        do: Application.delete_env(:ex_athena, atom)

    on_exit(fn ->
      for atom <- [:default_provider, :model | @all_provider_atoms],
          do: Application.delete_env(:ex_athena, atom)
    end)

    :ok
  end

  describe "pop_provider!/1" do
    test "uses :provider from opts when given" do
      assert {ExAthena.Providers.Mock, []} = Config.pop_provider!(provider: :mock)
    end

    test "falls back to :default_provider from env" do
      Application.put_env(:ex_athena, :default_provider, :mock)
      assert {ExAthena.Providers.Mock, []} = Config.pop_provider!([])
    end

    test "raises when no provider anywhere" do
      Application.put_env(:ex_athena, :default_provider, nil)

      assert_raise ArgumentError, ~r/no :provider passed/, fn ->
        Config.pop_provider!([])
      end
    end

    test "resolves module references directly" do
      assert {ExAthena.Providers.Mock, []} =
               Config.pop_provider!(provider: ExAthena.Providers.Mock)
    end

    test "rejects unknown provider atoms" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        Config.pop_provider!(provider: :nonexistent)
      end
    end
  end

  describe "get/4 tiered resolution" do
    test "per-call wins over provider env wins over top-level wins over default" do
      Application.put_env(:ex_athena, :ollama, model: "env-model")
      Application.put_env(:ex_athena, :model, "top-model")

      # per-call wins
      assert "call-model" =
               Config.get(ExAthena.Providers.ReqLLM, :model, [model: "call-model"], "default")

      # provider env wins over top-level
      assert "env-model" = Config.get(ExAthena.Providers.ReqLLM, :model, [], "default")

      # top-level wins over default when provider env doesn't set it
      Application.delete_env(:ex_athena, :ollama)

      assert "top-model" = Config.get(ExAthena.Providers.ReqLLM, :model, [], "default")

      # default when nothing is set
      Application.delete_env(:ex_athena, :model)

      assert "default" = Config.get(ExAthena.Providers.ReqLLM, :model, [], "default")
    end
  end

  describe "provider_opts/3 atom scoping" do
    test "does not leak a sibling provider's base_url across the shared ReqLLM module" do
      # :ollama and :gemini both map to ExAthena.Providers.ReqLLM. A configured
      # Ollama base_url must NOT bleed into a Gemini request (that 404s).
      Application.put_env(:ex_athena, :ollama, base_url: "http://localhost:11434")
      on_exit(fn -> Application.delete_env(:ex_athena, :ollama) end)

      gemini_opts =
        Config.provider_opts(ExAthena.Providers.ReqLLM, [provider: :gemini], :gemini)

      assert Keyword.get(gemini_opts, :base_url) == nil

      ollama_opts =
        Config.provider_opts(ExAthena.Providers.ReqLLM, [provider: :ollama], :ollama)

      assert Keyword.get(ollama_opts, :base_url) == "http://localhost:11434"
    end

    test "per-call opts still override the scoped provider env" do
      Application.put_env(:ex_athena, :ollama, base_url: "http://localhost:11434")
      on_exit(fn -> Application.delete_env(:ex_athena, :ollama) end)

      opts =
        Config.provider_opts(
          ExAthena.Providers.ReqLLM,
          [provider: :ollama, base_url: "http://example.test"],
          :ollama
        )

      assert Keyword.get(opts, :base_url) == "http://example.test"
    end
  end

  describe "provider_module/1" do
    test "resolves built-in atoms" do
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:ollama)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:openai)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:openai_compatible)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:llamacpp)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:claude)
      assert ExAthena.Providers.Mock = Config.provider_module(:mock)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:gemini)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:openrouter)
    end

    test "accepts modules that implement the behaviour" do
      assert ExAthena.Providers.Mock = Config.provider_module(ExAthena.Providers.Mock)
    end
  end

  describe "pop_provider!/1 with :gemini" do
    test "resolves to ReqLLM and injects google req_llm_provider_tag" do
      assert {ExAthena.Providers.ReqLLM, rest} =
               Config.pop_provider!(provider: :gemini, model: "gemini-2.5-flash")

      assert rest[:req_llm_provider_tag] == "google"
      assert rest[:model] == "gemini-2.5-flash"
      refute Keyword.has_key?(rest, :openai_compatible_backend)
    end
  end

  describe "req_llm_provider_tag/1" do
    test "returns google for :gemini" do
      assert "google" = Config.req_llm_provider_tag(:gemini)
    end

    test "returns nil for unknown atom when registry is not running" do
      assert nil == Config.req_llm_provider_tag(:nonexistent_provider)
    end

    test "returns tag from registry spec when registry has the provider" do
      dir = tmp_dir_create()

      write_json(dir, "custom.json", %{
        name: "my-local",
        adapter: "req_llm",
        req_llm_provider_tag: "openai"
      })

      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      assert "openai" == Config.req_llm_provider_tag(:"my-local")
    end

    test "returns nil for registry spec without req_llm_provider_tag" do
      dir = tmp_dir_create()
      write_json(dir, "custom.json", %{name: "my-mock", adapter: "mock"})
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      assert nil == Config.req_llm_provider_tag(:"my-mock")
    end

    test "returns openai for :openrouter" do
      assert "openai" = Config.req_llm_provider_tag(:openrouter)
    end
  end

  describe "provider_module/1 with registry fallthrough" do
    test "resolves registry-loaded providers by atom name" do
      dir = tmp_dir_create()
      write_json(dir, "custom.json", %{name: "my-mock", adapter: "mock"})
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      assert ExAthena.Providers.Mock = Config.provider_module(:"my-mock")
    end

    test "built-in providers still resolve when registry is running" do
      dir = tmp_dir_create()
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      assert ExAthena.Providers.Mock = Config.provider_module(:mock)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:ollama)
    end

    test "raises for unknown atom not in registry" do
      dir = tmp_dir_create()
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        Config.provider_module(:totally_unknown)
      end
    end
  end

  describe "list_providers/0" do
    test "includes all built-in provider atoms" do
      providers = Config.list_providers()
      names = Enum.map(providers, & &1.name)
      assert "ollama" in names
      assert "mock" in names
      assert "openai" in names
      assert "gemini" in names
    end

    test "all built-in entries have source: :builtin" do
      providers = Config.list_providers()
      builtin = Enum.filter(providers, &(&1.source == :builtin))
      assert length(builtin) == map_size(ExAthena.Config.builtin_providers())
    end

    test "includes registry specs when registry is running" do
      dir = tmp_dir_create()
      write_json(dir, "custom.json", %{name: "custom-prov", adapter: "mock"})
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      providers = Config.list_providers()
      registry_entry = Enum.find(providers, &(&1.name == "custom-prov"))
      assert registry_entry != nil
      assert registry_entry.source == :registry
      assert registry_entry.module == ExAthena.Providers.Mock
    end

    test "returns only built-ins when registry is not running" do
      providers = Config.list_providers()
      assert Enum.all?(providers, &(&1.source == :builtin))
    end
  end

  describe "pop_provider!/1 threads registry spec fields" do
    test "threads base_url from spec into opts" do
      dir = tmp_dir_create()

      write_json(dir, "openrouter.json", %{
        name: "openrouter",
        adapter: "req_llm",
        req_llm_provider_tag: "openrouter",
        base_url: "https://openrouter.ai/api/v1"
      })

      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {mod, opts} = Config.pop_provider!(provider: :openrouter)
      assert mod == ExAthena.Providers.ReqLLM
      assert opts[:req_llm_provider_tag] == "openrouter"
      assert opts[:base_url] == "https://openrouter.ai/api/v1"
    end

    test "threads extra_headers from spec into opts" do
      dir = tmp_dir_create()

      write_json(dir, "openrouter.json", %{
        name: "openrouter",
        adapter: "req_llm",
        extra_headers: %{"HTTP-Referer" => "https://myapp.io"}
      })

      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {_mod, opts} = Config.pop_provider!(provider: :openrouter)
      assert opts[:extra_headers] == %{"HTTP-Referer" => "https://myapp.io"}
    end

    test "does not thread extra_headers when map is empty" do
      dir = tmp_dir_create()
      write_json(dir, "groq.json", %{name: "groq", adapter: "req_llm", extra_headers: %{}})
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {_mod, opts} = Config.pop_provider!(provider: :groq)
      refute Keyword.has_key?(opts, :extra_headers)
    end

    test "threads api_key from spec into opts" do
      dir = tmp_dir_create()
      write_json(dir, "groq.json", %{name: "groq", adapter: "req_llm", api_key: "gsk-abc123"})
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {_mod, opts} = Config.pop_provider!(provider: :groq)
      assert opts[:api_key] == "gsk-abc123"
    end

    test "resolves api_key from api_key_env" do
      env_var = "EX_ATHENA_TEST_API_KEY_#{System.unique_integer([:positive])}"
      System.put_env(env_var, "resolved-key-value")
      on_exit(fn -> System.delete_env(env_var) end)

      dir = tmp_dir_create()

      write_json(dir, "custom.json", %{
        name: "custom-prov",
        adapter: "req_llm",
        api_key_env: env_var
      })

      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {_mod, opts} = Config.pop_provider!(provider: :"custom-prov")
      assert opts[:api_key] == "resolved-key-value"
    end

    test "api_key in opts wins over spec api_key" do
      dir = tmp_dir_create()
      write_json(dir, "groq.json", %{name: "groq", adapter: "req_llm", api_key: "spec-key"})
      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {_mod, opts} = Config.pop_provider!(provider: :groq, api_key: "call-key")
      assert opts[:api_key] == "call-key"
    end

    test "base_url in opts wins over spec base_url" do
      dir = tmp_dir_create()

      write_json(dir, "groq.json", %{
        name: "groq",
        adapter: "req_llm",
        base_url: "https://api.groq.com/openai/v1"
      })

      start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

      {_mod, opts} = Config.pop_provider!(provider: :groq, base_url: "https://override.example")
      assert opts[:base_url] == "https://override.example"
    end
  end

  # ── Helpers for registry-based tests ─────────────────────────────

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "ex_athena_cfg_#{System.unique_integer([:positive])}")
  end

  defp tmp_dir_create do
    dir = tmp_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_json(dir, filename, data) do
    File.write!(Path.join(dir, filename), Jason.encode!(data))
  end

  describe "pop_provider!/1 with :openrouter" do
    test "resolves to ReqLLM and injects openai req_llm_provider_tag" do
      assert {ExAthena.Providers.ReqLLM, rest} =
               Config.pop_provider!(
                 provider: :openrouter,
                 base_url: "https://openrouter.ai/api/v1",
                 model: "anthropic/claude-3.5-sonnet"
               )

      assert rest[:req_llm_provider_tag] == "openai"
      assert rest[:model] == "anthropic/claude-3.5-sonnet"
      refute Keyword.has_key?(rest, :openai_compatible_backend)
    end
  end

  describe "request_queue_max_depth/1" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ex_athena, :request_queue)

        for atom <- @all_provider_atoms,
            do: Application.delete_env(:ex_athena, atom)
      end)

      :ok
    end

    test "returns built-in defaults for known local providers" do
      assert Config.request_queue_max_depth(:ollama) == 2
      assert Config.request_queue_max_depth(:llamacpp) == 1
    end

    test "returns 3 for :exo" do
      assert Config.request_queue_max_depth(:exo) == 3
    end

    test "returns 10 for cloud providers" do
      assert Config.request_queue_max_depth(:openai) == 10
      assert Config.request_queue_max_depth(:anthropic) == 10
      assert Config.request_queue_max_depth(:claude) == 10
      assert Config.request_queue_max_depth(:gemini) == 10
      assert Config.request_queue_max_depth(:openrouter) == 10
    end

    test "returns 10 for unknown providers" do
      assert Config.request_queue_max_depth(:some_unknown_provider) == 10
    end

    test "per-provider config overrides built-in default" do
      Application.put_env(:ex_athena, :ollama, request_queue: [max_depth: 5])
      assert Config.request_queue_max_depth(:ollama) == 5
    end

    test "global max_depth overrides built-in default" do
      Application.put_env(:ex_athena, :request_queue, max_depth: 7)
      assert Config.request_queue_max_depth(:ollama) == 7
    end

    test "per-provider config wins over global max_depth" do
      Application.put_env(:ex_athena, :ollama, request_queue: [max_depth: 5])
      Application.put_env(:ex_athena, :request_queue, max_depth: 7)
      assert Config.request_queue_max_depth(:ollama) == 5
    end
  end

  describe "request_queue_enabled?/0" do
    setup do
      on_exit(fn -> Application.delete_env(:ex_athena, :request_queue) end)
      :ok
    end

    test "returns false when not configured" do
      Application.delete_env(:ex_athena, :request_queue)
      refute Config.request_queue_enabled?()
    end

    test "returns false when explicitly disabled" do
      Application.put_env(:ex_athena, :request_queue, enabled: false)
      refute Config.request_queue_enabled?()
    end

    test "returns true when enabled" do
      Application.put_env(:ex_athena, :request_queue, enabled: true)
      assert Config.request_queue_enabled?()
    end
  end
end
