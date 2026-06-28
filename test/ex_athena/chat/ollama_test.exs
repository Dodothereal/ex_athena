defmodule ExAthena.Chat.OllamaTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Ollama

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "list_models/1" do
    test "returns model names sorted alphabetically on a 200 response",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        body =
          Jason.encode!(%{
            "models" => [
              %{"name" => "qwen2.5-coder:14b", "size" => 1},
              %{"name" => "llama3.1:latest", "size" => 2},
              %{"name" => "mistral:7b", "size" => 3}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, ["llama3.1:latest", "mistral:7b", "qwen2.5-coder:14b"]} =
               Ollama.list_models(base_url: base_url)
    end

    test "strips a trailing /v1 from the configured base_url before hitting /api/tags",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"models" => []}))
      end)

      # Caller may pass the OpenAI-prefixed URL ExAthena uses internally;
      # the tags endpoint is on the bare host.
      assert {:ok, []} = Ollama.list_models(base_url: base_url <> "/v1")
    end

    test "returns {:error, :ollama_unreachable} when the connection is refused" do
      # 1 is reserved and will reject every connect attempt fast.
      assert {:error, :ollama_unreachable} =
               Ollama.list_models(base_url: "http://127.0.0.1:1")
    end

    test "returns {:error, {:http, status}} on a non-200 response",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, {:http, 500}} = Ollama.list_models(base_url: base_url)
    end

    test "returns {:error, :unexpected_response} when the body lacks a models array",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"unexpected" => "shape"}))
      end)

      assert {:error, :unexpected_response} = Ollama.list_models(base_url: base_url)
    end

    test "falls back to the configured base_url when none is passed" do
      original = Application.get_env(:ex_athena, :ollama)
      bypass = Bypass.open()

      on_exit(fn ->
        if original do
          Application.put_env(:ex_athena, :ollama, original)
        else
          Application.delete_env(:ex_athena, :ollama)
        end
      end)

      Application.put_env(:ex_athena, :ollama,
        base_url: "http://localhost:#{bypass.port}/v1",
        model: "ignored"
      )

      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"models" => [%{"name" => "x"}]}))
      end)

      assert {:ok, ["x"]} = Ollama.list_models([])
    end
  end

  describe "list_cloud_models/1" do
    test "appends -cloud to each catalog name so it is invocable via the local daemon",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        body =
          Jason.encode!(%{
            "models" => [%{"name" => "glm-5.2"}, %{"name" => "gpt-oss:120b"}]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, models} = Ollama.list_cloud_models(cloud_base_url: base_url)
      assert "glm-5.2-cloud" in models
      assert "gpt-oss:120b-cloud" in models
    end

    test "does not double-suffix a catalog name that already ends in -cloud",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/api/tags", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"models" => [%{"name" => "foo-cloud"}]}))
      end)

      assert {:ok, ["foo-cloud"]} = Ollama.list_cloud_models(cloud_base_url: base_url)
    end

    test "returns {:error, :ollama_unreachable} when the cloud catalog is unreachable" do
      assert {:error, :ollama_unreachable} =
               Ollama.list_cloud_models(cloud_base_url: "http://127.0.0.1:1")
    end
  end
end
