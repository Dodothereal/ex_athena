defmodule ExAthena.EmbedTest do
  use ExUnit.Case, async: false

  alias ExAthena.Embedding

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_athena, :mock)
      Application.delete_env(:ex_athena, :embedding_model)
    end)

    :ok
  end

  describe "ExAthena.embed/2 through the Mock provider" do
    test "returns a single vector for a string input" do
      assert {:ok, %Embedding{} = embedding} =
               ExAthena.embed("hello",
                 provider: :mock,
                 model: "nomic-embed-text",
                 mock: [embeddings: [[0.1, 0.2, 0.3]]]
               )

      assert embedding.embeddings == [[0.1, 0.2, 0.3]]
      assert embedding.model == "nomic-embed-text"
      assert embedding.provider == :mock
    end

    test "returns one vector per input for a batch" do
      assert {:ok, %Embedding{embeddings: vectors}} =
               ExAthena.embed(["a", "b"],
                 provider: :mock,
                 model: "nomic-embed-text",
                 mock: [embeddings: [[0.1], [0.2]]]
               )

      assert vectors == [[0.1], [0.2]]
    end

    test "a responder sees the raw input so hosts can stub per chunk" do
      responder = fn inputs -> Enum.map(inputs, fn text -> [byte_size(text) / 1] end) end

      assert {:ok, %Embedding{embeddings: [[3.0], [5.0]]}} =
               ExAthena.embed(["abc", "abcde"],
                 provider: :mock,
                 model: "nomic-embed-text",
                 mock: [embed_responder: responder]
               )
    end

    test "surfaces a scripted error" do
      assert {:error, :boom} =
               ExAthena.embed("hello",
                 provider: :mock,
                 model: "nomic-embed-text",
                 mock: [error: :boom]
               )
    end
  end

  describe "embedding model resolution" do
    test "falls back to the provider's :embedding_model config" do
      Application.put_env(:ex_athena, :mock, embedding_model: "configured-embed")

      assert {:ok, %Embedding{model: "configured-embed"}} =
               ExAthena.embed("hello", provider: :mock, mock: [embeddings: [[0.1]]])
    end

    test "a per-call :model wins over the configured embedding model" do
      Application.put_env(:ex_athena, :mock, embedding_model: "configured-embed")

      assert {:ok, %Embedding{model: "per-call"}} =
               ExAthena.embed("hello",
                 provider: :mock,
                 model: "per-call",
                 mock: [embeddings: [[0.1]]]
               )
    end

    test "the provider's chat :model is never used as the embedding model" do
      Application.put_env(:ex_athena, :mock, model: "chat-model")

      assert {:error, %ExAthena.Error{kind: :bad_request} = error} =
               ExAthena.embed("hello", provider: :mock, mock: [embeddings: [[0.1]]])

      assert error.message =~ "embedding model"
    end
  end

  describe "capability feature detection" do
    test "capabilities/1 reports embeddings support" do
      assert ExAthena.capabilities(:mock).embeddings == true
      assert ExAthena.capabilities(:ollama).embeddings == true
    end

    test "providers without an embed/2 callback return a :capability error" do
      assert {:error, %ExAthena.Error{kind: :capability} = error} =
               ExAthena.embed("hello", provider: :claude_code, model: "whatever")

      assert error.message =~ "embeddings"
    end
  end
end
