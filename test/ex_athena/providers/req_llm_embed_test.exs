defmodule ExAthena.Providers.ReqLLMEmbedTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Embedding, Error}
  alias ExAthena.Providers.ReqLLM, as: Adapter

  @model "nomic-embed-text"

  setup do
    bypass = Bypass.open()

    opts = [
      openai_compatible_backend: :ollama,
      req_llm_provider_tag: "openai",
      base_url: "http://localhost:#{bypass.port}",
      model: @model,
      timeout_ms: 5_000
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  defp embeddings_body(vectors) do
    data =
      vectors
      |> Enum.with_index()
      |> Enum.map(fn {vector, index} ->
        %{"object" => "embedding", "index" => index, "embedding" => vector}
      end)

    %{
      "object" => "list",
      "data" => data,
      "model" => @model,
      "usage" => %{"prompt_tokens" => 7, "total_tokens" => 7}
    }
  end

  defp expect_embeddings(bypass, vectors, on_body) do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      on_body.(Jason.decode!(raw))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(embeddings_body(vectors)))
    end)
  end

  test "embeds a single string into a one-element vector list", %{bypass: bypass, opts: opts} do
    parent = self()

    expect_embeddings(bypass, [[0.1, 0.2, 0.3]], fn body ->
      send(parent, {:body, body})
    end)

    assert {:ok, %Embedding{} = embedding} = Adapter.embed("hello", opts)
    assert embedding.embeddings == [[0.1, 0.2, 0.3]]
    assert embedding.model == @model
    assert embedding.provider == :req_llm
    assert embedding.usage[:input_tokens] == 7

    assert_received {:body, body}
    assert body["input"] == "hello"
    assert body["model"] == @model
  end

  test "embeds a batch of strings in one request", %{bypass: bypass, opts: opts} do
    parent = self()

    expect_embeddings(bypass, [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]], fn body ->
      send(parent, {:body, body})
    end)

    assert {:ok, %Embedding{embeddings: vectors}} =
             Adapter.embed(["one", "two", "three"], opts)

    assert vectors == [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]

    assert_received {:body, body}
    assert body["input"] == ["one", "two", "three"]
  end

  test "maps HTTP failures onto ExAthena.Error", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, Jason.encode!(%{"error" => %{"message" => "model not found"}}))
    end)

    assert {:error, %Error{} = error} = Adapter.embed("hello", opts)
    assert error.provider == :req_llm
  end

  test "errors when no embedding model is configured", %{opts: opts} do
    assert {:error, %Error{kind: :bad_request} = error} =
             Adapter.embed("hello", Keyword.delete(opts, :model))

    assert error.message =~ "embedding model"
  end

  test "declares the embeddings capability" do
    assert Adapter.capabilities().embeddings == true
  end
end
