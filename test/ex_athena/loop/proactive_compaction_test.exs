defmodule ExAthena.Loop.ProactiveCompactionTest do
  @moduledoc """
  Verifies the kernel's proactive `maybe_compact` builds its token estimate
  from the full request — including the system prompt — not just the
  messages. A prompt-heavy agent (large tool descriptions / skill catalog)
  must trip `should_compact?` before the real prompt overflows the window.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Result}

  # Records the estimate `maybe_compact` passes to `should_compact?`, then
  # declines to compact so the run proceeds normally. Runs in the loop
  # process, which is the test process — so the process dictionary is shared.
  defmodule EstimateSpy do
    @behaviour ExAthena.Compactor

    @impl true
    def should_compact?(_state, estimate) do
      Process.put(:proactive_estimate, estimate)
      false
    end

    @impl true
    def compact(_state, _estimate), do: :skip
  end

  test "proactive estimate includes the system prompt, not just the messages" do
    # ~10_000 tokens of system prompt (40_000 bytes / 4) with a trivial
    # message history — the prompt is the dominant cost.
    big_prompt = String.duplicate("x", 40_000)

    {:ok, %Result{}} =
      Loop.run("hi",
        provider: :mock,
        mock: [text: "done"],
        tools: [],
        system_prompt: big_prompt,
        compactor: EstimateSpy,
        memory: false,
        skills: %{}
      )

    estimate = Process.get(:proactive_estimate)
    assert estimate != nil, "should_compact? was never called"

    assert estimate.tokens >= 10_000,
           "proactive estimate must account for the system prompt (got #{estimate.tokens})"
  end
end
