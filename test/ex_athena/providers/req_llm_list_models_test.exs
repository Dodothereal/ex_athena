defmodule ExAthena.Providers.ReqLLMListModelsTest do
  use ExUnit.Case, async: false

  alias ExAthena.{Model, ModelDiscovery}
  alias ExAthena.Providers.ReqLLM, as: Adapter

  setup do
    ModelDiscovery.clear_cache()
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp tags(conn, names) do
    body = Jason.encode!(%{"models" => Enum.map(names, &%{"name" => &1})})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, body)
  end

  test "advertises model listing as a capability so hosts can feature-detect" do
    assert Adapter.capabilities().model_listing == true
  end

  test "enumerates an ollama daemon through the provider abstraction", ctx do
    Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
      tags(conn, ["qwen3-coder:30b"])
    end)

    assert {:ok, [%Model{id: "qwen3-coder:30b", source: :server}]} =
             Adapter.list_models(
               openai_compatible_backend: :ollama,
               req_llm_provider_tag: "openai",
               base_url: ctx.base_url
             )
  end

  test "serves a second call from the shared cache rather than re-fetching", ctx do
    # Bypass.expect_once fails the test if the endpoint is hit twice.
    Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
      tags(conn, ["cached-model"])
    end)

    opts = [
      openai_compatible_backend: :ollama,
      req_llm_provider_tag: "openai",
      base_url: ctx.base_url
    ]

    assert {:ok, [%Model{id: "cached-model"}]} = Adapter.list_models(opts)
    assert {:ok, [%Model{id: "cached-model"}]} = Adapter.list_models(opts)
  end

  test "caches per base_url, so two local servers never share a list", ctx do
    other = Bypass.open()

    Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn -> tags(conn, ["first"]) end)
    Bypass.expect_once(other, "GET", "/api/tags", fn conn -> tags(conn, ["second"]) end)

    base = [openai_compatible_backend: :ollama, req_llm_provider_tag: "openai"]

    assert {:ok, [%Model{id: "first"}]} = Adapter.list_models(base ++ [base_url: ctx.base_url])

    assert {:ok, [%Model{id: "second"}]} =
             Adapter.list_models(base ++ [base_url: "http://localhost:#{other.port}"])
  end

  test "cache: false refetches on demand", ctx do
    Bypass.expect(ctx.bypass, "GET", "/api/tags", fn conn -> tags(conn, ["m"]) end)

    opts = [
      openai_compatible_backend: :ollama,
      req_llm_provider_tag: "openai",
      base_url: ctx.base_url
    ]

    assert {:ok, _} = Adapter.list_models(opts)
    assert {:ok, [%Model{id: "m"}]} = Adapter.list_models(opts ++ [cache: false])
  end

  test "falls back to the catalog for providers with no listing endpoint" do
    assert {:ok, models} = Adapter.list_models(req_llm_provider_tag: "anthropic")
    assert Enum.all?(models, &(&1.source == :catalog))
  end
end
