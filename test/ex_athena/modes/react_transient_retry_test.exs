defmodule ExAthena.Modes.ReactTransientRetryTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Error, Loop, Result}

  test "a transient provider error on the first iteration does not crash on `not nil`" do
    # Regression: `not state.meta[:retried_transient?]` raised ArgumentError
    # (`:erlang.not(nil)`) the FIRST time a transient error occurred, because
    # :retried_transient? is unset. A recoverable EXO hiccup on iter 0 became a
    # hard "run crashed: ArgumentError" instead of the intended one-time retry.
    err = %Error{kind: :server_error, message: "boom"}

    assert {:ok, %Result{} = result} =
             Loop.run("hi",
               provider: :mock,
               mock: [error: err],
               memory: false,
               conclusions: false,
               max_iterations: 2
             )

    # After the single retry both attempts fail → the run halts gracefully as
    # an execution error rather than crashing.
    assert result.finish_reason == :error_during_execution
  end
end
