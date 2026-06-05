defmodule ExAthena.Loop.FenceFilterTest do
  @moduledoc """
  Tests for the pure streaming fence filter that strips `~~~tool_call ... ~~~`
  blocks from chunked assistant text. Fences may split at any byte boundary,
  so the filter holds partial-marker tails as pending until they resolve.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Loop.FenceFilter

  # Push every chunk through a fresh filter, returning {final_state, visible}.
  defp run_chunks(chunks) do
    Enum.reduce(chunks, {FenceFilter.new(), ""}, fn chunk, {state, acc} ->
      {state, visible} = FenceFilter.push(state, chunk)
      {state, acc <> visible}
    end)
  end

  defp visible(chunks) do
    {state, out} = run_chunks(chunks)
    out <> FenceFilter.flush(state)
  end

  test "plain text passes through unchanged in a single chunk" do
    {_state, out} = run_chunks(["hello world, no fences here.\n"])
    assert out == "hello world, no fences here.\n"
  end

  test "plain text passes through unchanged across multiple chunks" do
    assert visible(["hel", "lo ", "wor", "ld\n"]) == "hello world\n"
  end

  test "whole fence in one chunk is removed" do
    chunk = "before\n~~~tool_call\n{\"name\":\"bash\"}\n~~~\nafter"
    assert visible([chunk]) == "before\n\nafter"
  end

  test "fence split across many chunks is removed" do
    chunks = [
      "before\n",
      "~~~to",
      "ol_c",
      "all\n{\"name\":",
      "\"bash\"}",
      "\n~~~",
      "\nafter"
    ]

    assert visible(chunks) == "before\n\nafter"
  end

  test "open marker split across three chunks is removed" do
    chunks = ["~", "~~tool_", "call\nbody\n~~~", "\ntail"]
    assert visible(chunks) == "\ntail"
  end

  test "close marker split as newline-tilde then two tildes is removed" do
    chunks = ["~~~tool_call\n{\"name\":\"bash\"}", "\n~", "~~", "\nafter"]
    assert visible(chunks) == "\nafter"
  end

  test "literal marker prefix that never completes is emitted intact" do
    assert visible(["~~~tool_caller text"]) == "~~~tool_caller text"
  end

  test "marker prefix split across chunks that never completes is emitted intact" do
    assert visible(["~~~tool_c", "aller text"]) == "~~~tool_caller text"
  end

  test "full marker followed by non-newline text is emitted intact" do
    # Whitespace after the marker is held until we know whether a newline
    # follows; once a non-whitespace char arrives it is all released.
    assert visible(["~~~tool_call ", "X then more"]) == "~~~tool_call X then more"
  end

  test "two fences with text between" do
    chunks = [
      "intro\n~~~tool_call\n{\"name\":\"a\"}\n~~~\nmiddle\n",
      "~~~tool_call\n{\"name\":\"b\"}\n~~~\noutro"
    ]

    assert visible(chunks) == "intro\n\nmiddle\n\noutro"
  end

  test "flush returns trailing partial marker held outside a fence" do
    {state, out} = run_chunks(["text~~"])
    assert out == "text"
    assert FenceFilter.flush(state) == "~~"
  end

  test "flush swallows an unterminated fence" do
    {state, out} = run_chunks(["~~~tool_call\n{\"name\":\"bash\""])
    assert out == ""
    assert FenceFilter.flush(state) == ""
  end

  test "horizontal whitespace between marker and newline is part of the fence" do
    chunk = "before\n~~~tool_call  \n{\"name\":\"bash\"}\n~~~\nafter"
    assert visible([chunk]) == "before\n\nafter"
  end

  test "whitespace tail of the marker split across chunks still opens the fence" do
    chunks = ["~~~tool_call \t", " \n{\"name\":\"x\"}\n~~~", "done"]
    assert visible(chunks) == "done"
  end
end
