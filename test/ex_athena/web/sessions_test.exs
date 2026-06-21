defmodule ExAthena.Web.SessionsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Sessions
  alias ExAthena.Result

  describe "merge_run_result/4 — durable run-result append" do
    test "appends the assistant message and refreshes ex_messages/session when new" do
      data = %{
        id: "s",
        display_messages: [%{id: "u1", role: :user, text: "hi"}],
        ex_messages: [:old],
        provider_session_id: nil
      }

      msg = %{id: "a1", role: :assistant, text: "the answer"}
      result = %Result{messages: [:m1, :m2], session_id: "ps"}

      assert {:save, merged} = Sessions.merge_run_result(data, "a1", msg, result)
      assert List.last(merged.display_messages) == msg
      assert merged.ex_messages == [:m1, :m2]
      assert merged.provider_session_id == "ps"
    end

    test "is a no-op when the message id is already present (LiveView already saved it)" do
      data = %{
        id: "s",
        display_messages: [%{id: "a1", role: :assistant, text: "rich version"}],
        ex_messages: []
      }

      msg = %{id: "a1", role: :assistant, text: "lean version"}
      result = %Result{messages: [], session_id: nil}

      assert :skip = Sessions.merge_run_result(data, "a1", msg, result)
    end

    test "keeps existing ex_messages/provider id when the result carries none" do
      data = %{id: "s", display_messages: [], ex_messages: [:keep], provider_session_id: "old"}
      result = %Result{messages: nil, session_id: nil}

      assert {:save, merged} = Sessions.merge_run_result(data, "a1", %{id: "a1"}, result)
      assert merged.ex_messages == [:keep]
      assert merged.provider_session_id == "old"
    end
  end

  describe "final_message_text/2 — surfacing the finish deliverable" do
    test "uses the deliverable as the message when nothing was streamed" do
      result = %Result{finish_reason: :submitted, deliverable: "the final answer"}
      assert Sessions.final_message_text("", result) == "the final answer"
      assert Sessions.final_message_text("   \n ", result) == "the final answer"
    end

    test "appends the deliverable to streamed text so the submitted answer shows" do
      result = %Result{finish_reason: :submitted, deliverable: "summary line"}
      assert Sessions.final_message_text("the story", result) == "the story\n\nsummary line"
    end

    test "does not duplicate when streamed text already contains the deliverable" do
      result = %Result{finish_reason: :submitted, deliverable: "the answer"}

      assert Sessions.final_message_text("here is the answer in full", result) ==
               "here is the answer in full"
    end

    test "non-submitted runs keep the streamed text unchanged" do
      assert Sessions.final_message_text("streamed", %Result{finish_reason: :stop}) == "streamed"

      assert Sessions.final_message_text("streamed", %Result{
               finish_reason: :submitted,
               deliverable: nil
             }) == "streamed"
    end
  end
end
