defmodule ExAthena.Chat.ExoTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Exo

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "list_models/1" do
    test "returns downloaded model ids sorted alphabetically on a 200 response",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["status"] == "downloaded"

        body =
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{"id" => "mlx-community/Qwen3-4B-4bit", "context_length" => 32_768},
              %{"id" => "mlx-community/Llama-3.2-1B-Instruct-4bit", "context_length" => 131_072}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, ["mlx-community/Llama-3.2-1B-Instruct-4bit", "mlx-community/Qwen3-4B-4bit"]} =
               Exo.list_models(base_url: base_url)
    end

    test "strips a trailing /v1 from the base_url before hitting /v1/models",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"data" => []}))
      end)

      assert {:ok, []} = Exo.list_models(base_url: base_url <> "/v1")
    end

    test "returns {:error, :exo_unreachable} when the connection is refused" do
      # 1 is reserved and will reject every connect attempt fast.
      assert {:error, :exo_unreachable} = Exo.list_models(base_url: "http://127.0.0.1:1")
    end

    test "returns {:error, {:http, status}} on a non-200 response",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, {:http, 500}} = Exo.list_models(base_url: base_url)
    end

    test "returns {:error, :unexpected_response} when the body lacks a data array",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"unexpected" => "shape"}))
      end)

      assert {:error, :unexpected_response} = Exo.list_models(base_url: base_url)
    end

    test "falls back to the configured base_url when none is passed" do
      original = Application.get_env(:ex_athena, :exo)
      bypass = Bypass.open()

      on_exit(fn ->
        if original do
          Application.put_env(:ex_athena, :exo, original)
        else
          Application.delete_env(:ex_athena, :exo)
        end
      end)

      Application.put_env(:ex_athena, :exo, base_url: "http://localhost:#{bypass.port}/v1")

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"data" => [%{"id" => "x"}]}))
      end)

      assert {:ok, ["x"]} = Exo.list_models([])
    end
  end
end
