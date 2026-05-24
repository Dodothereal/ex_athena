defmodule ExAthena.RequestTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Messages, Request}
  alias ExAthena.Messages.{ContentPart, Message}

  describe "new/2 — text-only (existing behaviour unchanged)" do
    test "nil prompt with no messages yields empty messages list" do
      req = Request.new(nil, [])
      assert req.messages == []
    end

    test "empty string prompt yields empty messages list" do
      req = Request.new("", [])
      assert req.messages == []
    end

    test "string prompt appended as user message with string content" do
      req = Request.new("hello", [])
      assert [%Message{role: :user, content: "hello"}] = req.messages
    end

    test "pre-built :messages preserved and prompt appended" do
      existing = [Messages.user("first")]
      req = Request.new("second", messages: existing)
      assert [%Message{content: "first"}, %Message{content: "second"}] = req.messages
    end

    test "empty images list leaves string content unchanged" do
      req = Request.new("hello", images: [])
      assert [%Message{role: :user, content: "hello"}] = req.messages
    end
  end

  describe "new/2 — images: shorthand" do
    test "inline image + prompt → user message with [text_part | image_part]" do
      png = <<0::8>>
      req = Request.new("describe", images: [%{data: png, media_type: "image/png"}])

      assert [%Message{role: :user, content: parts}] = req.messages
      assert [%ContentPart{type: :text, text: "describe"}, %ContentPart{type: :image}] = parts
    end

    test "image_url + prompt → user message with [text_part, image_url_part]" do
      req = Request.new("describe", images: [%{url: "https://example.com/img.png"}])

      assert [%Message{role: :user, content: parts}] = req.messages

      assert [
               %ContentPart{type: :text},
               %ContentPart{type: :image_url, url: "https://example.com/img.png"}
             ] =
               parts
    end

    test "image without explicit media_type defaults to image/png" do
      req = Request.new("describe", images: [%{data: <<1, 2, 3>>}])

      assert [%Message{role: :user, content: [_text, img]}] = req.messages
      assert %ContentPart{type: :image, media_type: "image/png"} = img
    end

    test "nil prompt + images → user message containing only image parts" do
      req = Request.new(nil, images: [%{data: <<0>>, media_type: "image/jpeg"}])

      assert [%Message{role: :user, content: [%ContentPart{type: :image}]}] = req.messages
    end

    test "empty prompt + images → user message containing only image parts" do
      req = Request.new("", images: [%{data: <<0>>, media_type: "image/jpeg"}])

      assert [%Message{role: :user, content: [%ContentPart{type: :image}]}] = req.messages
    end

    test "images + pre-built messages with string user message → image parts appended to last user" do
      existing = [Messages.user("first")]

      req =
        Request.new(nil, messages: existing, images: [%{data: <<0>>, media_type: "image/png"}])

      assert [%Message{role: :user, content: parts}] = req.messages
      assert [%ContentPart{type: :text, text: "first"}, %ContentPart{type: :image}] = parts
    end

    test "images + pre-built messages with already-list content → image parts appended" do
      existing = [Messages.user([ContentPart.text("first")])]

      req =
        Request.new(nil, messages: existing, images: [%{data: <<0>>, media_type: "image/png"}])

      assert [%Message{role: :user, content: parts}] = req.messages
      assert [%ContentPart{type: :text, text: "first"}, %ContentPart{type: :image}] = parts
    end

    test "images + pre-built messages with no user message → new user message appended" do
      existing = [Messages.system("system msg")]

      req =
        Request.new(nil, messages: existing, images: [%{data: <<0>>, media_type: "image/png"}])

      assert [
               %Message{role: :system},
               %Message{role: :user, content: [%ContentPart{type: :image}]}
             ] =
               req.messages
    end

    test "multiple images in list → all converted to ContentParts" do
      req =
        Request.new("look",
          images: [
            %{data: <<1>>, media_type: "image/png"},
            %{data: <<2>>, media_type: "image/jpeg"}
          ]
        )

      assert [%Message{role: :user, content: parts}] = req.messages
      assert length(parts) == 3

      assert [%ContentPart{type: :text}, %ContentPart{type: :image}, %ContentPart{type: :image}] =
               parts
    end

    test "images + prompt with pre-built messages → prompt+images appended, existing preserved" do
      existing = [Messages.system("sys"), Messages.user("prior")]

      req =
        Request.new("new prompt",
          messages: existing,
          images: [%{data: <<0>>, media_type: "image/png"}]
        )

      assert [
               %Message{role: :system},
               %Message{role: :user, content: "prior"},
               %Message{role: :user, content: parts}
             ] =
               req.messages

      assert [%ContentPart{type: :text, text: "new prompt"}, %ContentPart{type: :image}] = parts
    end
  end

  describe "new/2 — invalid prompt shape (fail loud)" do
    # The prompt contract is String.t() | nil. A non-string prompt — most
    # commonly a content-block list like [%{type: "text"}, %{type: "image"}]
    # built by a caller that should have used the :images opt — used to fall
    # through to a silent empty user message, swallowing the whole turn.
    test "content-block-list prompt raises ArgumentError" do
      blocks = [
        %{type: "text", text: "look at this"},
        %{type: "image", source: %{type: "base64", media_type: "image/png", data: "abc"}}
      ]

      assert_raise ArgumentError, ~r/expected a String or nil/, fn ->
        Request.new(blocks, [])
      end
    end

    test "content-block-list prompt raises even when :images opt is also given" do
      blocks = [%{type: "text", text: "hi"}]

      assert_raise ArgumentError, ~r/expected a String or nil/, fn ->
        Request.new(blocks, images: [%{data: <<0>>, media_type: "image/png"}])
      end
    end

    test "non-string scalar prompt raises ArgumentError" do
      assert_raise ArgumentError, ~r/expected a String or nil/, fn ->
        Request.new(123, [])
      end
    end
  end
end
