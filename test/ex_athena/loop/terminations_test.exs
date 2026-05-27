defmodule ExAthena.Loop.TerminationsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Loop.Terminations

  describe "all/0" do
    test "enumerates every known subtype" do
      assert :stop in Terminations.all()
      assert :submitted in Terminations.all()
      assert :error_max_turns in Terminations.all()
      assert :error_max_budget_usd in Terminations.all()
      assert :error_during_execution in Terminations.all()
      assert :error_max_structured_output_retries in Terminations.all()
      assert :error_consecutive_mistakes in Terminations.all()
      assert :error_halted in Terminations.all()
      assert :error_compaction_failed in Terminations.all()
      assert :error_prompt_too_long in Terminations.all()
      assert :error_no_progress in Terminations.all()
      assert :error_schema_validation in Terminations.all()
      assert :error_provider_auth in Terminations.all()
    end
  end

  describe "success?/1 and error?/1" do
    test ":stop is success, not error" do
      assert Terminations.success?(:stop)
      refute Terminations.error?(:stop)
    end

    test ":submitted is success, not error" do
      assert Terminations.success?(:submitted)
      refute Terminations.error?(:submitted)
    end

    test "every error subtype is error, not success" do
      for subtype <- Terminations.all() -- [:stop, :submitted] do
        refute Terminations.success?(subtype), "#{subtype} should not be success"
        assert Terminations.error?(subtype), "#{subtype} should be error"
      end
    end
  end

  describe "category/1" do
    test ":stop is :success" do
      assert Terminations.category(:stop) == :success
    end

    test ":submitted is :success" do
      assert Terminations.category(:submitted) == :success
    end

    test "cap-tripping terminations are :capacity" do
      assert Terminations.category(:error_max_turns) == :capacity
      assert Terminations.category(:error_max_budget_usd) == :capacity
      assert Terminations.category(:error_max_structured_output_retries) == :capacity
      assert Terminations.category(:error_consecutive_mistakes) == :capacity
      assert Terminations.category(:error_prompt_too_long) == :capacity
      assert Terminations.category(:error_no_progress) == :capacity
    end

    test "execution errors are :retryable" do
      assert Terminations.category(:error_during_execution) == :retryable
    end

    test "schema validation errors are :retryable" do
      assert Terminations.category(:error_schema_validation) == :retryable
    end

    test "halts and compaction failures are :fatal" do
      assert Terminations.category(:error_halted) == :fatal
      assert Terminations.category(:error_compaction_failed) == :fatal
    end

    test "provider auth errors are :fatal" do
      assert Terminations.category(:error_provider_auth) == :fatal
    end
  end
end
