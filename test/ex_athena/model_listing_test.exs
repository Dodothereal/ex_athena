defmodule ExAthena.ModelListingTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Error, Model, ModelListing}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp tags_response(names) do
    Jason.encode!(%{"models" => Enum.map(names, &%{"name" => &1})})
  end

  defp openai_models_response(ids) do
    Jason.encode!(%{"data" => Enum.map(ids, &%{"id" => &1, "object" => "model"})})
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, body)
  end

  describe "ollama backend" do
    test "enumerates the local daemon's installed models, sorted", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
        json(conn, tags_response(["qwen3-coder:30b", "llama3.1:latest"]))
      end)

      assert {:ok, [first, second]} =
               ModelListing.list(
                 openai_compatible_backend: :ollama,
                 base_url: ctx.base_url
               )

      assert %Model{id: "llama3.1:latest", source: :server, provider: :ollama} = first
      assert %Model{id: "qwen3-coder:30b"} = second
    end

    test "hits the bare host even when the caller passes the OpenAI /v1 base_url", ctx do
      # ExAthena appends /v1 internally for chat; /api/tags lives above it.
      Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
        json(conn, tags_response(["mistral:7b"]))
      end)

      assert {:ok, [%Model{id: "mistral:7b"}]} =
               ModelListing.list(
                 openai_compatible_backend: :ollama,
                 base_url: ctx.base_url <> "/v1"
               )
    end

    test "appends the cloud catalogue when asked, suffixing -cloud", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
        json(conn, tags_response(["local-model"]))
      end)

      cloud = Bypass.open()

      Bypass.expect_once(cloud, "GET", "/api/tags", fn conn ->
        json(conn, tags_response(["glm-5.2"]))
      end)

      assert {:ok, models} =
               ModelListing.list(
                 openai_compatible_backend: :ollama,
                 base_url: ctx.base_url,
                 include_cloud: true,
                 cloud_base_url: "http://localhost:#{cloud.port}"
               )

      assert Enum.map(models, & &1.id) == ["glm-5.2-cloud", "local-model"]
    end

    test "a failing cloud fetch does not lose the local models", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
        json(conn, tags_response(["local-model"]))
      end)

      assert {:ok, [%Model{id: "local-model"}]} =
               ModelListing.list(
                 openai_compatible_backend: :ollama,
                 base_url: ctx.base_url,
                 include_cloud: true,
                 cloud_base_url: "http://127.0.0.1:1"
               )
    end
  end

  describe "openai-compatible backends" do
    test "llamacpp reads /v1/models", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/v1/models", fn conn ->
        json(conn, openai_models_response(["qwen3.gguf"]))
      end)

      assert {:ok, [%Model{id: "qwen3.gguf", provider: :llamacpp, source: :server}]} =
               ModelListing.list(
                 openai_compatible_backend: :llamacpp,
                 base_url: ctx.base_url
               )
    end

    test "exo asks only for downloaded models", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/v1/models", fn conn ->
        assert conn.query_string == "status=downloaded"
        json(conn, openai_models_response(["mlx-community/Llama-3.2-1B"]))
      end)

      assert {:ok, [%Model{id: "mlx-community/Llama-3.2-1B", provider: :exo}]} =
               ModelListing.list(
                 openai_compatible_backend: :exo,
                 base_url: ctx.base_url
               )
    end

    test "a remote OpenAI-wire provider reads /v1/models with its bearer token", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/v1/models", fn conn ->
        assert ["Bearer sk-test"] = Plug.Conn.get_req_header(conn, "authorization")
        json(conn, openai_models_response(["gpt-4o"]))
      end)

      assert {:ok, [%Model{id: "gpt-4o"}]} =
               ModelListing.list(
                 req_llm_provider_tag: "openai",
                 base_url: ctx.base_url,
                 api_key: "sk-test"
               )
    end
  end

  describe "catalog-backed providers" do
    test "anthropic falls back to the llm_db catalog when there is no endpoint to ask" do
      assert {:ok, models} = ModelListing.list(req_llm_provider_tag: "anthropic")

      assert models != []
      assert Enum.all?(models, &(&1.source == :catalog))
      assert Enum.all?(models, &(&1.provider == :anthropic))
      # The catalog knows context windows; that is the reason to prefer it.
      assert Enum.any?(models, &is_integer(&1.context_window))
    end

    test "an unknown provider tag reports a capability error rather than crashing" do
      assert {:error, %Error{kind: :capability}} =
               ModelListing.list(req_llm_provider_tag: "not-a-real-provider")
    end
  end

  describe "errors" do
    test "surfaces an HTTP status as a canonical error", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, %Error{kind: :server_error, status: 500}} =
               ModelListing.list(openai_compatible_backend: :ollama, base_url: ctx.base_url)
    end

    test "surfaces an unreachable server as a transport error" do
      assert {:error, %Error{kind: :transport, raw: :ollama_unreachable}} =
               ModelListing.list(
                 openai_compatible_backend: :ollama,
                 base_url: "http://127.0.0.1:1"
               )
    end

    test "surfaces an undecodable body", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
        json(conn, Jason.encode!(%{"unexpected" => true}))
      end)

      assert {:error, %Error{kind: :server_error, raw: :unexpected_response}} =
               ModelListing.list(openai_compatible_backend: :ollama, base_url: ctx.base_url)
    end
  end
end
