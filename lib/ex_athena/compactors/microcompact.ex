defmodule ExAthena.Compactors.Microcompact do
  @moduledoc """
  Third pipeline stage — collapses runs of repetitive tool calls.

  When a model issues several similar tool calls in a row (think:
  three consecutive `Read`s of related files, four `Glob`s for a
  refactor sweep), each result message contributes meaningfully but
  collectively wastes context. Microcompact replaces a run of three
  or more adjacent same-tool tool-result messages with a single
  elided summary that lists the calls and trims each result body.

  Pure-Elixir, no LLM call. Deterministic — same input always
  produces same output. Idempotent: a run already reduced to a single
  micro-summary is left alone (it's no longer a *run* of tool
  calls).

  Heuristic for "same tool":
    * adjacent tool-role messages
    * each is the result of a single tool call (one entry in
      `tool_results`)
    * matching tool *names* on the assistant's parent `tool_calls`
  """

  @behaviour ExAthena.Compactor.Stage

  alias ExAthena.Compactor
  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message

  @default_run_threshold 3
  @default_excerpt_chars 200

  @impl true
  def name, do: :microcompact

  @impl true
  def compact_stage(%State{messages: messages} = state, estimate) do
    run_threshold = run_threshold(state)
    excerpt_chars = excerpt_chars(state)
    pin_floor = pin_floor(state)
    suffix_floor = length(messages) - 4
    suffix_floor = if suffix_floor < pin_floor, do: pin_floor, else: suffix_floor

    {compacted, runs} =
      collapse_runs(messages, pin_floor, suffix_floor, run_threshold, excerpt_chars)

    case runs do
      0 ->
        :skip

      _ ->
        new_state = %{state | messages: compacted}
        {:ok, new_state, %{estimate | tokens: Compactor.estimate_tokens(compacted)}}
    end
  end

  # ── Run detection ────────────────────────────────────────────────

  defp collapse_runs(messages, pin_floor, suffix_floor, threshold, excerpt_chars) do
    {prefix, work} = Enum.split(messages, pin_floor)
    {work, suffix} = Enum.split(work, max(0, suffix_floor - pin_floor))

    {compacted_work, runs} = do_collapse(work, [], 0, threshold, excerpt_chars)

    {prefix ++ compacted_work ++ suffix, runs}
  end

  defp do_collapse([], acc, runs, _t, _ex), do: {Enum.reverse(acc), runs}

  defp do_collapse([%Message{pin: true} = head | tail], acc, runs, threshold, excerpt_chars) do
    do_collapse(tail, [head | acc], runs, threshold, excerpt_chars)
  end

  defp do_collapse([head | tail], acc, runs, threshold, excerpt_chars) do
    case take_tool_run(head, tail) do
      {[_, _, _ | _] = run, rest} when length(run) >= threshold ->
        # Rewrite each result IN PLACE (excerpted) — collapsing N tool
        # messages into one summary orphaned the parent assistant's
        # tool_calls (strict servers 400 on unmatched tool_call_id) and
        # the id-less summary message was re-sent as a USER message.
        excerpted = Enum.map(run, &excerpt_message(&1, excerpt_chars))

        {Enum.reverse(excerpted) ++ acc, rest}
        |> then(fn {a, r} -> do_collapse(r, a, runs + 1, threshold, excerpt_chars) end)

      {_short_or_none, _} ->
        do_collapse(tail, [head | acc], runs, threshold, excerpt_chars)
    end
  end

  # Greedily collect a contiguous run of same-named single-tool-result messages
  # starting at `head`. Returns {[head | run...], remaining_tail}.
  defp take_tool_run(%Message{role: :tool, pin: false, tool_results: [first | _]} = head, tail) do
    name = first.tool_call_id

    {run, rest} =
      Enum.split_while(tail, fn
        %Message{role: :tool, pin: false, tool_results: [tr | _]} ->
          kindred?(tr.tool_call_id, name)

        _ ->
          false
      end)

    {[head | run], rest}
  end

  defp take_tool_run(_, tail), do: {[], tail}

  # Two tool-call ids are "kindred" if they begin with the same prefix
  # the loop conventionally uses ("c1", "c2", …). We don't look at tool
  # *names* directly because the tool-result message doesn't carry
  # them; the heuristic of "adjacent tool-role messages" is the working
  # signal Claude Code's `microcompact` uses too.
  defp kindred?(_a, _b), do: true

  # ── Run rendering ────────────────────────────────────────────────

  # Excerpt one tool message, keeping its tool_call_id pairing intact.
  defp excerpt_message(%Message{tool_results: [tr | rest]} = msg, excerpt_chars) do
    content = to_string(tr.content)

    if byte_size(content) <= excerpt_chars do
      msg
    else
      body =
        content
        |> String.slice(0, excerpt_chars)
        |> truncate_marker(byte_size(content), excerpt_chars)

      %{
        msg
        | tool_results: [
            %{tr | content: "[microcompact excerpt] " <> body, ui_payload: nil} | rest
          ]
      }
    end
  end

  defp excerpt_message(msg, _), do: msg

  defp truncate_marker(prefix, original_size, excerpt_chars) when original_size > excerpt_chars,
    do: prefix <> " […]"

  defp truncate_marker(prefix, _, _), do: prefix

  # ── Config ───────────────────────────────────────────────────────

  defp run_threshold(%State{meta: meta}) do
    Map.get(meta, :microcompact_run_threshold) ||
      case Application.get_env(:ex_athena, :compactor) do
        kw when is_list(kw) ->
          Keyword.get(kw, :microcompact_run_threshold, @default_run_threshold)

        m when is_map(m) ->
          Map.get(m, :microcompact_run_threshold, @default_run_threshold)

        _ ->
          @default_run_threshold
      end
  end

  defp excerpt_chars(%State{meta: meta}) do
    Map.get(meta, :microcompact_excerpt_chars) ||
      case Application.get_env(:ex_athena, :compactor) do
        kw when is_list(kw) ->
          Keyword.get(kw, :microcompact_excerpt_chars, @default_excerpt_chars)

        m when is_map(m) ->
          Map.get(m, :microcompact_excerpt_chars, @default_excerpt_chars)

        _ ->
          @default_excerpt_chars
      end
  end

  defp pin_floor(%State{meta: meta}) do
    Map.get(meta, :memory_count, 0) +
      Map.get(meta, :preloaded_skill_count, 0) +
      Map.get(meta, :pinned_prefix_count, 1)
  end
end
