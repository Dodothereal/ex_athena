defmodule ExAthenaTest do
  use ExUnit.Case, async: true

  describe "query/2" do
    test "dispatches to the provider and returns its response" do
      assert {:ok, response} =
               ExAthena.query("hi",
                 provider: :mock,
                 mock: [text: "pong"]
               )

      assert response.text == "pong"
      assert response.provider == :mock
      assert response.finish_reason == :stop
    end

    test "supplies the provider with a Request struct" do
      responder = fn request ->
        assert [user_msg] = request.messages
        assert user_msg.role == :user
        assert user_msg.content == "hello"
        %ExAthena.Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end

      assert {:ok, %{text: "ok"}} =
               ExAthena.query("hello", provider: :mock, mock: [responder: responder])
    end

    test "raises when no provider is configured" do
      prior = Application.get_env(:ex_athena, :default_provider)
      Application.put_env(:ex_athena, :default_provider, nil)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:ex_athena, :default_provider)
          v -> Application.put_env(:ex_athena, :default_provider, v)
        end
      end)

      assert_raise ArgumentError, ~r/no :provider passed/, fn ->
        ExAthena.query("hi")
      end
    end

    test "images: shorthand reaches the provider as ContentPart content" do
      alias ExAthena.Messages.ContentPart

      png = <<0::8>>

      responder = fn request ->
        assert [user_msg] = request.messages

        assert [%ContentPart{type: :text, text: "describe"}, %ContentPart{type: :image}] =
                 user_msg.content

        %ExAthena.Response{
          text: "saw image",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end

      assert {:ok, response} =
               ExAthena.query("describe",
                 provider: :mock,
                 mock: [responder: responder],
                 images: [%{data: png, media_type: "image/png"}]
               )

      assert response.text == "saw image"
    end
  end

  describe "stream/3" do
    test "delivers events to the callback and returns the final response" do
      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      events = [
        %ExAthena.Streaming.Event{type: :text_delta, data: "hel"},
        %ExAthena.Streaming.Event{type: :text_delta, data: "lo"}
      ]

      assert {:ok, %ExAthena.Response{text: "hello"}} =
               ExAthena.stream("hi", callback,
                 provider: :mock,
                 mock: [text: "hello"],
                 mock_events: events
               )

      assert_receive {:event, %ExAthena.Streaming.Event{type: :text_delta, data: "hel"}}
      assert_receive {:event, %ExAthena.Streaming.Event{type: :text_delta, data: "lo"}}
      assert_receive {:event, %ExAthena.Streaming.Event{type: :stop}}
    end

    test "images: shorthand reaches the provider as ContentPart content via stream" do
      alias ExAthena.Messages.ContentPart

      png = <<0::8>>

      responder = fn request ->
        assert [user_msg] = request.messages

        assert [%ContentPart{type: :text, text: "describe"}, %ContentPart{type: :image}] =
                 user_msg.content

        %ExAthena.Response{
          text: "saw image",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      end

      assert {:ok, response} =
               ExAthena.stream("describe", fn _ -> :ok end,
                 provider: :mock,
                 mock: [responder: responder],
                 images: [%{data: png, media_type: "image/png"}]
               )

      assert response.text == "saw image"
    end
  end

  describe "capabilities/1" do
    test "returns a provider's capability map" do
      assert %{streaming: true, native_tool_calls: true} = ExAthena.capabilities(:mock)
    end

    test "accepts a module directly" do
      assert %{streaming: true} = ExAthena.capabilities(ExAthena.Providers.Mock)
    end
  end

  describe "supports_multimodal?/0" do
    test "returns true" do
      assert ExAthena.supports_multimodal?() == true
    end
  end
end
