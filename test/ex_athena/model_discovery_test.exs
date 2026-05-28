defmodule ExAthena.ModelDiscoveryTest do
  use ExUnit.Case, async: false

  alias ExAthena.{ModelDiscovery, ProviderSpec}

  setup do
    ModelDiscovery.clear_cache()
    :ok
  end

  describe "list_models/1 with no model_discovery block" do
    test "returns {:error, :no_model_discovery} when model_discovery is nil" do
      spec = %ProviderSpec{
        name: "no-disc",
        adapter: :mock,
        module: ExAthena.Providers.Mock,
        extra_headers: %{}
      }

      assert {:error, :no_model_discovery} = ModelDiscovery.list_models(spec)
    end
  end

  describe "extract_models/2 path extraction (pure)" do
    test "extracts from data.id path" do
      body = %{"data" => [%{"id" => "model-a"}, %{"id" => "model-b"}]}
      assert ["model-a", "model-b"] = ModelDiscovery.extract_models(body, "data.id")
    end

    test "extracts from root list with single-key path" do
      body = [%{"id" => "m1"}, %{"id" => "m2"}]
      assert ["m1", "m2"] = ModelDiscovery.extract_models(body, "id")
    end

    test "returns root strings when path is empty and body is a list of strings" do
      body = ["m1", "m2", "m3"]
      assert ["m1", "m2", "m3"] = ModelDiscovery.extract_models(body, "")
    end

    test "returns empty list when path key is missing" do
      body = %{"items" => [%{"name" => "m1"}]}
      assert [] = ModelDiscovery.extract_models(body, "data.id")
    end

    test "returns empty list for non-list, non-map body" do
      assert [] = ModelDiscovery.extract_models("not-a-map", "data.id")
    end

    test "handles nested path with intermediate list" do
      body = %{"results" => %{"models" => [%{"id" => "x"}, %{"id" => "y"}]}}
      assert ["x", "y"] = ModelDiscovery.extract_models(body, "results.models.id")
    end
  end

  describe "list_models/1 with HTTP (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
    end

    test "fetches models and returns extracted list", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        body =
          Jason.encode!(%{
            "data" => [%{"id" => "model-alpha"}, %{"id" => "model-beta"}]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      spec = %ProviderSpec{
        name: "test-provider-#{System.unique_integer([:positive])}",
        adapter: :req_llm,
        module: ExAthena.Providers.ReqLLM,
        extra_headers: %{},
        model_discovery: %{
          "url" => "#{base_url}/v1/models",
          "path" => "data.id"
        }
      }

      assert {:ok, models} = ModelDiscovery.list_models(spec)
      assert "model-alpha" in models
      assert "model-beta" in models
    end

    test "caches result on second call without hitting HTTP again",
         %{bypass: bypass, base_url: base_url} do
      name = "caching-prov-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        body = Jason.encode!(%{"data" => [%{"id" => "cached-model"}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      spec = %ProviderSpec{
        name: name,
        adapter: :req_llm,
        module: ExAthena.Providers.ReqLLM,
        extra_headers: %{},
        model_discovery: %{
          "url" => "#{base_url}/models",
          "path" => "data.id",
          "ttl_seconds" => 60
        }
      }

      assert {:ok, ["cached-model"]} = ModelDiscovery.list_models(spec)
      # Second call uses cache — Bypass would raise if a second request hit
      assert {:ok, ["cached-model"]} = ModelDiscovery.list_models(spec)
    end

    test "returns error tuple on HTTP error status", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
      end)

      spec = %ProviderSpec{
        name: "err-prov-#{System.unique_integer([:positive])}",
        adapter: :req_llm,
        module: ExAthena.Providers.ReqLLM,
        extra_headers: %{},
        model_discovery: %{"url" => "#{base_url}/models", "path" => "data.id"}
      }

      assert {:error, {:http_error, 401}} = ModelDiscovery.list_models(spec)
    end

    test "sends extra headers in the request when headers are in model_discovery",
         %{bypass: bypass, base_url: base_url} do
      name = "header-prov-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom-auth") == ["my-token"]

        body = Jason.encode!(%{"data" => [%{"id" => "m1"}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      spec = %ProviderSpec{
        name: name,
        adapter: :req_llm,
        module: ExAthena.Providers.ReqLLM,
        extra_headers: %{},
        model_discovery: %{
          "url" => "#{base_url}/models",
          "path" => "data.id",
          "headers" => %{"x-custom-auth" => "my-token"}
        }
      }

      assert {:ok, ["m1"]} = ModelDiscovery.list_models(spec)
    end
  end
end
