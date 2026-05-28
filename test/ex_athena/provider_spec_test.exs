defmodule ExAthena.ProviderSpecTest do
  use ExUnit.Case, async: true

  alias ExAthena.ProviderSpec

  describe "from_json/1" do
    test "parses a full valid spec" do
      json = %{
        "name" => "my-ollama",
        "adapter" => "req_llm",
        "req_llm_provider_tag" => "openai",
        "base_url" => "http://localhost:11434/v1",
        "api_key" => "not-needed",
        "default_model" => "qwen3-coder",
        "metadata" => %{"note" => "local"}
      }

      assert {:ok, spec} = ProviderSpec.from_json(json)
      assert spec.name == "my-ollama"
      assert spec.adapter == :req_llm
      assert spec.module == ExAthena.Providers.ReqLLM
      assert spec.req_llm_provider_tag == "openai"
      assert spec.base_url == "http://localhost:11434/v1"
      assert spec.api_key == "not-needed"
      assert spec.default_model == "qwen3-coder"
      assert spec.metadata == %{"note" => "local"}
    end

    test "parses a minimal spec (only required fields)" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "min", "adapter" => "mock"})
      assert spec.name == "min"
      assert spec.adapter == :mock
      assert spec.module == ExAthena.Providers.Mock
      assert spec.req_llm_provider_tag == nil
      assert spec.base_url == nil
      assert spec.api_key == nil
      assert spec.default_model == nil
    end

    test "defaults metadata to empty map when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.metadata == %{}
    end

    test "parses extra_headers map" do
      json = %{
        "name" => "openrouter",
        "adapter" => "req_llm",
        "extra_headers" => %{"HTTP-Referer" => "https://myapp.io", "X-Title" => "MyApp"}
      }

      assert {:ok, spec} = ProviderSpec.from_json(json)
      assert spec.extra_headers == %{"HTTP-Referer" => "https://myapp.io", "X-Title" => "MyApp"}
    end

    test "defaults extra_headers to empty map when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.extra_headers == %{}
    end

    test "parses api_key_env" do
      json = %{"name" => "x", "adapter" => "req_llm", "api_key_env" => "OPENROUTER_API_KEY"}
      assert {:ok, spec} = ProviderSpec.from_json(json)
      assert spec.api_key_env == "OPENROUTER_API_KEY"
    end

    test "defaults api_key_env to nil when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.api_key_env == nil
    end

    test "parses model_discovery block" do
      json = %{
        "name" => "x",
        "adapter" => "req_llm",
        "model_discovery" => %{
          "url" => "https://openrouter.ai/api/v1/models",
          "path" => "data.id",
          "ttl_seconds" => 300
        }
      }

      assert {:ok, spec} = ProviderSpec.from_json(json)

      assert spec.model_discovery == %{
               "url" => "https://openrouter.ai/api/v1/models",
               "path" => "data.id",
               "ttl_seconds" => 300
             }
    end

    test "defaults model_discovery to nil when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.model_discovery == nil
    end

    test "parses mock adapter" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "test", "adapter" => "mock"})
      assert spec.module == ExAthena.Providers.Mock
    end

    test "returns error for missing name" do
      assert {:error, reason} = ProviderSpec.from_json(%{"adapter" => "req_llm"})
      assert reason =~ "name"
    end

    test "returns error for missing adapter" do
      assert {:error, reason} = ProviderSpec.from_json(%{"name" => "x"})
      assert reason =~ "adapter"
    end

    test "returns error for empty name string" do
      assert {:error, reason} = ProviderSpec.from_json(%{"name" => "", "adapter" => "mock"})
      assert reason =~ "name"
    end

    test "returns error for non-string name" do
      assert {:error, reason} = ProviderSpec.from_json(%{"name" => 123, "adapter" => "mock"})
      assert reason =~ "name"
    end

    test "returns error for unknown adapter" do
      assert {:error, reason} =
               ProviderSpec.from_json(%{"name" => "x", "adapter" => "unknown_thing"})

      assert reason =~ "unknown adapter"
    end

    test "parses display_name, api_key_prompt, api_key_env, extra_headers" do
      json = %{
        "name" => "my-openai",
        "adapter" => "req_llm",
        "display_name" => "My OpenAI",
        "api_key_prompt" => true,
        "api_key_env" => "MY_OPENAI_API_KEY",
        "extra_headers" => %{"X-Custom" => "value"}
      }

      assert {:ok, spec} = ProviderSpec.from_json(json)
      assert spec.display_name == "My OpenAI"
      assert spec.api_key_prompt == true
      assert spec.api_key_env == "MY_OPENAI_API_KEY"
      assert spec.extra_headers == %{"X-Custom" => "value"}
    end

    test "display_name defaults to nil when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.display_name == nil
    end

    test "api_key_prompt defaults to false when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.api_key_prompt == false
    end

    test "extra_headers defaults to empty map when not provided" do
      assert {:ok, spec} = ProviderSpec.from_json(%{"name" => "x", "adapter" => "mock"})
      assert spec.extra_headers == %{}
    end
  end
end
