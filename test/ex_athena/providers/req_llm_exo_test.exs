defmodule ExAthena.Providers.ReqLLMExoTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.Message
  alias ExAthena.Providers.ReqLLM, as: Adapter
  alias ExAthena.{Error, Request, Response}

  @model "mlx-community/Llama-3.2-1B-Instruct-4bit"

  setup do
    bypass = Bypass.open()

    request = %Request{
      messages: [%Message{role: :user, content: "hi"}],
      model: @model,
      timeout_ms: 5_000
    }

    opts = [
      openai_compatible_backend: :exo,
      req_llm_provider_tag: "openai",
      base_url: "http://localhost:#{bypass.port}",
      poll_interval_ms: 10,
      timeout_ms: 50
    ]

    {:ok, bypass: bypass, request: request, opts: opts}
  end

  defp active_instances_body do
    %{
      "11111111-aaaa-bbbb-cccc-000000000001" => %{
        "MlxRingInstance" => %{
          "shardAssignments" => %{"modelId" => @model}
        }
      }
    }
  end

  test "query returns a provider error when the exo instance never becomes ready",
       %{bypass: bypass, request: request, opts: opts} do
    Bypass.expect(bypass, "GET", "/state/instances", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{}))
    end)

    Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"message" => "Command received."}))
    end)

    assert {:error, %Error{} = error} = Adapter.query(request, opts)
    assert error.message =~ "exo has no active instance"
    assert error.message =~ @model
  end

  test "query proceeds to chat completions when an instance is active",
       %{bypass: bypass, request: request, opts: opts} do
    Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(active_instances_body()))
    end)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body =
        Jason.encode!(%{
          "id" => "chatcmpl-1",
          "object" => "chat.completion",
          "created" => 1_700_000_000,
          "model" => @model,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "Hello!"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 5,
            "completion_tokens" => 2,
            "total_tokens" => 7
          }
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, %Response{} = response} = Adapter.query(request, opts)
    assert response.text == "Hello!"
  end

  test "non-exo backends skip the pre-flight entirely",
       %{bypass: bypass, request: request, opts: opts} do
    # No /state/instances or /place_instance expectations: any such request
    # would fail the test. Only the chat endpoint is stubbed.
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body =
        Jason.encode!(%{
          "id" => "chatcmpl-2",
          "object" => "chat.completion",
          "created" => 1_700_000_000,
          "model" => @model,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "ok"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    opts = Keyword.put(opts, :openai_compatible_backend, :llamacpp)
    assert {:ok, %Response{}} = Adapter.query(request, opts)
  end
end
