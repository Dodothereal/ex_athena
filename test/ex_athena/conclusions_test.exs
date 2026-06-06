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
end
