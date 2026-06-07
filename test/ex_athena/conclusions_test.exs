defmodule ExAthena.ConclusionsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Conclusions

  describe "from_turn/2 — stated marker" do
    test "extracts a trailing CONCLUSION: line" do
      text = "I checked the router.\n\nCONCLUSION: the route is missing."

      assert {:ok, %{text: "the route is missing.", source: :stated}} =
               Conclusions.from_turn(text, [])
    end

    test "uses the LAST marker when several appear" do
      text = "CONCLUSION: first guess.\nMore work...\nCONCLUSION: final answer."

      assert {:ok, %{text: "final answer.", source: :stated}} =
               Conclusions.from_turn(text, [])
    end

    test "marker wins even when the turn also made tool calls" do
      text = "Reading files.\nCONCLUSION: need the schema next."

      assert {:ok, %{text: "need the schema next.", source: :stated}} =
               Conclusions.from_turn(text, ["read"])
    end
  end

  describe "from_turn/2 — tail fallback" do
    test "falls back to the final paragraph when no marker and no tools" do
      text = "Some setup.\n\nThe PORT defaults to 4000 via runtime.exs."

      assert {:ok, %{text: "The PORT defaults to 4000 via runtime.exs.", source: :tail}} =
               Conclusions.from_turn(text, [])
    end

    test "truncates a long tail paragraph" do
      long = String.duplicate("word ", 100)
      assert {:ok, %{text: text, source: :tail}} = Conclusions.from_turn(long, [])
      assert String.length(text) <= 163
      assert String.ends_with?(text, "…")
    end
  end

  describe "from_turn/2 — derived from tool activity" do
    test "derives from tool names when the turn had calls but no usable text" do
      assert {:ok, %{text: text, source: :derived}} = Conclusions.from_turn("", ["read", "grep"])
      assert text =~ "read"
      assert text =~ "grep"
    end

    test "blank-only text with tools still derives" do
      assert {:ok, %{source: :derived}} = Conclusions.from_turn("  ", ["edit"])
    end
  end

  describe "from_turn/2 — nothing to conclude" do
    test "returns :none for blank text and no tools" do
      assert Conclusions.from_turn("", []) == :none
      assert Conclusions.from_turn("   \n  ", []) == :none
      assert Conclusions.from_turn(nil, []) == :none
    end
  end

  describe "from_turn/3 — thinking as a source (Qwen-style turns)" do
    # Thinking models put EVERYTHING in <think>; the text channel of a
    # tool-call turn is blank. Without these sources every conclusion was
    # the useless "ran bash" fallback.
    test "a CONCLUSION marker inside thinking wins over the derived fallback" do
      thinking = "Let me check the dirs first.\nCONCLUSION: no blog directory exists yet."

      assert {:ok, %{text: "no blog directory exists yet.", source: :stated}} =
               Conclusions.from_turn("", thinking, ["bash"])
    end

    test "a marker in TEXT still wins over one in thinking" do
      assert {:ok, %{text: "from text.", source: :stated}} =
               Conclusions.from_turn(
                 "CONCLUSION: from text.",
                 "CONCLUSION: from thinking.",
                 []
               )
    end

    test "blank text + markerless thinking → the WHOLE thinking blob is the conclusion" do
      # Tail-only extraction yielded forward-looking junk ("Let me
      # explore…") and prompt nagging didn't bind the model — so the full
      # reasoning carries the turn's record instead.
      thinking = """
      I listed the directories.

      The project has web/priv/services but no blog directory at all.

      Let me check the controllers next.
      """

      assert {:ok, %{text: text, source: :thinking}} =
               Conclusions.from_turn("", thinking, ["bash"])

      assert text =~ "I listed the directories."
      assert text =~ "no blog directory"
      assert text =~ "Let me check the controllers next."
    end

    test "a huge thinking blob is truncated, head-first" do
      thinking = String.duplicate("reasoning ", 500)

      assert {:ok, %{text: text, source: :thinking}} =
               Conclusions.from_turn("", thinking, ["bash"])

      assert String.length(text) <= 1_001
    end

    test "the TEXT tail skips forward-looking intent paragraphs and picks the finding" do
      text = """
      The project has web/priv/services with 6 markdown files but no blog
      directory exists at all.

      Let me start by looking at the blog controller to understand the pattern.
      """

      assert {:ok, %{text: out, source: :tail}} = Conclusions.from_turn(text, nil, ["bash"])
      assert out =~ "no blog"
      refute out =~ "Let me"
    end

    test "all-intent text still falls back to its last paragraph" do
      assert {:ok, %{text: "Let me explore the directories first.", source: :tail}} =
               Conclusions.from_turn("Let me explore the directories first.", nil, ["bash"])
    end

    test "no text, no thinking, tools only → derived (unchanged)" do
      assert {:ok, %{source: :derived}} = Conclusions.from_turn("", nil, ["bash"])
    end
  end
end
