defmodule ExAthena.Web.Live.ChatLiveTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Live.ChatLive

  describe "filter_models/2 — model search box" do
    @models [
      "mlx-community/Qwen3.5-9B-4bit",
      "mlx-community/Qwen3.6-27B-4bit",
      "mlx-community/gemma-4-e4b-it-4bit",
      "anthropic/claude-3.5-sonnet"
    ]

    test "case-insensitive substring match (anywhere in the id)" do
      assert ChatLive.filter_models(@models, "qwen3.5") == ["mlx-community/Qwen3.5-9B-4bit"]
      # matches the part after the slash, which datalist prefix-matching misses
      assert ChatLive.filter_models(@models, "sonnet") == ["anthropic/claude-3.5-sonnet"]
      assert "mlx-community/gemma-4-e4b-it-4bit" in ChatLive.filter_models(@models, "GEMMA")
    end

    test "blank query returns all (capped); no match returns []" do
      assert ChatLive.filter_models(@models, "") == @models
      assert ChatLive.filter_models(@models, "   ") == @models
      assert ChatLive.filter_models(@models, "nope") == []
    end

    test "caps the result count" do
      many = for i <- 1..200, do: "openrouter/model-#{i}"
      assert length(ChatLive.filter_models(many, "model")) == 60
    end
  end
end
