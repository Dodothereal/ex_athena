defmodule ExAthena.Web.Live.ChatLiveTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Live.ChatLive
  alias ExAthena.Result

  describe "final_message_text/2 — surfacing the finish deliverable" do
    test "uses the deliverable as the message when nothing was streamed" do
      result = %Result{finish_reason: :submitted, deliverable: "the final answer"}
      assert ChatLive.final_message_text("", result) == "the final answer"
      assert ChatLive.final_message_text("   \n ", result) == "the final answer"
    end

    test "appends the deliverable to streamed text so the submitted answer shows" do
      result = %Result{finish_reason: :submitted, deliverable: "summary line"}
      assert ChatLive.final_message_text("the story", result) == "the story\n\nsummary line"
    end

    test "does not duplicate when streamed text already contains the deliverable" do
      result = %Result{finish_reason: :submitted, deliverable: "the answer"}

      assert ChatLive.final_message_text("here is the answer in full", result) ==
               "here is the answer in full"
    end

    test "non-submitted runs keep the streamed text unchanged" do
      assert ChatLive.final_message_text("streamed", %Result{finish_reason: :stop}) == "streamed"

      assert ChatLive.final_message_text("streamed", %Result{
               finish_reason: :submitted,
               deliverable: nil
             }) == "streamed"
    end
  end
end
