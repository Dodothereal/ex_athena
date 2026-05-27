defmodule ExAthena.ResultTest do
  use ExUnit.Case, async: true

  alias ExAthena.Result

  test "success?/1 reflects the finish_reason subtype" do
    assert Result.success?(%Result{finish_reason: :stop})
    assert Result.success?(%Result{finish_reason: :submitted})
    refute Result.success?(%Result{finish_reason: :error_max_turns})
  end

  test "error?/1 is the inverse of success?" do
    refute Result.error?(%Result{finish_reason: :stop})
    refute Result.error?(%Result{finish_reason: :submitted})
    assert Result.error?(%Result{finish_reason: :error_halted})
    assert Result.error?(%Result{finish_reason: :error_during_execution})
    assert Result.error?(%Result{finish_reason: :error_schema_validation})
    assert Result.error?(%Result{finish_reason: :error_provider_auth})
  end

  test "category/1 delegates to Terminations" do
    assert Result.category(%Result{finish_reason: :stop}) == :success
    assert Result.category(%Result{finish_reason: :submitted}) == :success
    assert Result.category(%Result{finish_reason: :error_max_turns}) == :capacity
    assert Result.category(%Result{finish_reason: :error_during_execution}) == :retryable
    assert Result.category(%Result{finish_reason: :error_halted}) == :fatal
  end

  test "category/1 returns :fatal for provider auth errors" do
    assert Result.category(%Result{finish_reason: :error_provider_auth}) == :fatal
  end

  test "category/1 returns :retryable for schema validation errors" do
    assert Result.category(%Result{finish_reason: :error_schema_validation}) == :retryable
  end

  test "default struct has sane zero values" do
    assert %Result{
             text: nil,
             messages: [],
             finish_reason: :stop,
             iterations: 0,
             tool_calls_made: 0,
             usage: nil,
             cost_usd: nil,
             error_diagnostic: nil,
             deliverable: nil
           } = %Result{}
  end

  test "deliverable is nil by default" do
    assert %Result{deliverable: nil} = %Result{}
  end

  test "deliverable is populated for :submitted runs" do
    result = %Result{finish_reason: :submitted, deliverable: "my plan"}
    assert result.deliverable == "my plan"
    assert result.finish_reason == :submitted
  end

  test "no_progress_snapshot is nil by default" do
    assert %Result{no_progress_snapshot: nil} = %Result{}
  end

  test "no_progress_snapshot is populated for :error_no_progress" do
    msgs = [%{role: :assistant, content: "stuck"}]
    result = %Result{finish_reason: :error_no_progress, no_progress_snapshot: msgs}
    assert result.no_progress_snapshot == msgs
  end
end
