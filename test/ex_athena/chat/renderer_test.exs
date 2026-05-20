defmodule ExAthena.Chat.RendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ExAthena.Chat.Renderer
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result

  describe "render_event/1" do
    test ":content writes the delta verbatim with no trailing newline" do
      output = capture_io(fn -> Renderer.render_event({:content, "Hello "}) end)
      assert output == "Hello "
    end

    test ":tool_call prints a one-line arrow with the tool name and a preview of args" do
      tc = %ToolCall{id: "1", name: "Read", arguments: %{"path" => "lib/foo.ex"}}

      output = capture_io(fn -> Renderer.render_event({:tool_call, tc}) end)

      # Strip ANSI escapes to keep assertions readable.
      stripped = strip_ansi(output)
      assert stripped =~ "→ Read"
      assert stripped =~ "path"
      assert stripped =~ "lib/foo.ex"
    end

    test ":tool_result prints a one-line arrow with a preview of the result" do
      tr = %ToolResult{tool_call_id: "1", content: "file contents here", is_error: false}

      output = capture_io(fn -> Renderer.render_event({:tool_result, tr}) end)

      assert strip_ansi(output) =~ "← file contents here"
    end

    test ":tool_result marks errors visibly" do
      tr = %ToolResult{tool_call_id: "1", content: "boom", is_error: true}

      output = capture_io(fn -> Renderer.render_event({:tool_result, tr}) end)

      stripped = strip_ansi(output)
      assert stripped =~ "←"
      assert stripped =~ "boom"
    end

    test ":tool_result truncates very long previews" do
      long = String.duplicate("x", 1_000)
      tr = %ToolResult{tool_call_id: "1", content: long, is_error: false}

      output = capture_io(fn -> Renderer.render_event({:tool_result, tr}) end)

      stripped = strip_ansi(output)
      # Some truncation indicator appears, and the line is well under the raw length.
      assert String.length(stripped) < String.length(long)
    end

    test ":error renders a yellow warning line and stays on one line" do
      output = capture_io(fn -> Renderer.render_event({:error, :rate_limited}) end)

      stripped = strip_ansi(output)
      assert stripped =~ "rate_limited"
      assert stripped =~ "warn" or stripped =~ "warning"
    end

    test ":compaction renders a compact summary line" do
      output =
        capture_io(fn ->
          Renderer.render_event({:compaction, %{before: 12_000, after: 4_000, reason: :over_cap}})
        end)

      stripped = strip_ansi(output)
      assert stripped =~ "12000"
      assert stripped =~ "4000"
    end

    test ":done emits a trailing newline and nothing else" do
      output =
        capture_io(fn ->
          Renderer.render_event({:done, %Result{text: "ok", finish_reason: :stop}})
        end)

      assert output == "\n"
    end

    test "unknown events are silently ignored" do
      output = capture_io(fn -> Renderer.render_event({:totally_made_up, "x"}) end)
      assert output == ""
    end
  end

  describe "status_text/1" do
    test "renders a single-line status with model, mode, iteration, tokens, cost separated by ·" do
      status = %{
        model: "llama3.1",
        mode: :react,
        iteration: 3,
        usage: %{input_tokens: 120, output_tokens: 45},
        cost_usd: 0.0042
      }

      text =
        status
        |> Renderer.status_text()
        |> Owl.Data.to_chardata()
        |> IO.iodata_to_binary()
        |> strip_ansi()

      assert text =~ "llama3.1"
      assert text =~ "react"
      assert text =~ "iter=3"
      assert text =~ "120/45 tok"
      assert text =~ "$0.0042"
      # Fields separated by middle-dot for readability
      assert text =~ " · "
    end
  end

  describe "assistant_prefix/1" do
    test "returns a styled prefix containing the model name and a ▸ arrow" do
      text =
        "qwen3.5:latest"
        |> Renderer.assistant_prefix()
        |> Owl.Data.to_chardata()
        |> IO.iodata_to_binary()
        |> strip_ansi()

      assert text =~ "qwen3.5:latest"
      assert text =~ "▸"
    end
  end

  defp strip_ansi(string) do
    Regex.replace(~r/\e\[[0-9;]*m/, string, "")
  end
end
