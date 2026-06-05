defmodule ExAthena.Chat.ExoTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Exo

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  @model "mlx-community/Llama-3.2-1B-Instruct-4bit"

  defp instances_body(model, tag \\ "MlxRingInstance") do
    %{
      "11111111-aaaa-bbbb-cccc-000000000001" => %{
        tag => %{
          "instanceId" => "11111111-aaaa-bbbb-cccc-000000000001",
          "shardAssignments" => %{"modelId" => model, "runnerToShard" => %{}},
          "hostsByNode" => %{}
        }
      }
    }
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

  describe "ensure_instance/2" do
    test "returns :ok without placing when an instance is already active",
         %{bypass: bypass, base_url: base_url} do
      # Only GET /state/instances is expected; any POST /place_instance would
      # make Bypass fail the test as an unexpected request.
      Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(instances_body(@model)))
      end)

      assert :ok = Exo.ensure_instance(@model, base_url: base_url)
    end

    test "recognizes MlxJacclInstance-tagged instances",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(instances_body(@model, "MlxJacclInstance")))
      end)

      assert :ok = Exo.ensure_instance(@model, base_url: base_url)
    end

    test "places an instance and polls until it appears",
         %{bypass: bypass, base_url: base_url} do
      agent = start_supervised!({Agent, fn -> false end})

      Bypass.expect(bypass, "GET", "/state/instances", fn conn ->
        body = if Agent.get(agent, & &1), do: instances_body(@model), else: %{}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"model_id" => @model} = Jason.decode!(raw)
        Agent.update(agent, fn _ -> true end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"message" => "Command received."}))
      end)

      assert :ok =
               Exo.ensure_instance(@model,
                 base_url: base_url,
                 poll_interval_ms: 10,
                 timeout_ms: 1_000
               )
    end

    test "returns {:error, :exo_instance_unavailable} when the instance never appears",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end)

      Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"message" => "Command received."}))
      end)

      assert {:error, :exo_instance_unavailable} =
               Exo.ensure_instance(@model,
                 base_url: base_url,
                 poll_interval_ms: 10,
                 timeout_ms: 50
               )
    end

    test "returns {:error, :exo_unreachable} when the connection is refused" do
      assert {:error, :exo_unreachable} =
               Exo.ensure_instance(@model, base_url: "http://127.0.0.1:1")
    end

    test "returns {:error, {:http, status}} when place_instance fails",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end)

      Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "Insufficient memory"}))
      end)

      assert {:error, {:http, 400}} = Exo.ensure_instance(@model, base_url: base_url)
    end
  end
end
