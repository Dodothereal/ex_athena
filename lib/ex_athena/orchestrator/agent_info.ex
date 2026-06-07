defmodule ExAthena.Orchestrator.AgentInfo do
  @moduledoc """
  Observable state of one agent (the main loop or a subagent) in an
  orchestrated run — the pure functional core of
  `ExAthena.Orchestrator.Coordinator`.

  All updates are pure reducers over loop events (`apply_event/2`) and
  todo-list rewrites (`set_todos/2`), so every state transition is unit
  testable without processes (jido-style logic/runtime split).

  ## Status machine

      :running ⇄ :waiting_gpu        (queue_wait events)
      :running ⇄ :stalling           (repeated identical conclusions)
      :running → :done | :failed     ({:done, Result} by category)
      any non-terminal → :failed     (fail/1 — run process died)

  Terminal statuses (`:done`, `:failed`, `:timeout`) are sticky.

  ## Todo ledger

  The model speaks the dumb full-rewrite `todo_write` interface (idempotent,
  survives small-model slop); this module diffs successive rewrites by
  content to assign **stable ids** — the Claude Code task-ledger pattern,
  kept runtime-side so the model never does id bookkeeping. Invariants
  enforced in code: at most one `:in_progress` item (later ones demoted),
  and `complete_todo/2` for runtime-derived completion (e.g. when a linked
  subagent succeeds).
  """

  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result

  @transcript_max_entries 30
  @transcript_entry_max_chars 400
  # Coalesced thinking/content blocks may grow much larger than tool rows.
  @transcript_text_max_chars 4_000
  @conclusions_cap 50
  @summary_max_chars 160

  @type status :: :queued | :running | :waiting_gpu | :stalling | :done | :failed | :timeout

  @type todo :: %{
          id: pos_integer(),
          content: String.t(),
          status: :pending | :in_progress | :completed,
          active_form: String.t() | nil
        }

  defstruct id: nil,
            name: nil,
            prompt_summary: nil,
            status: :running,
            todos: [],
            next_todo_id: 1,
            conclusions: [],
            current_action: nil,
            iteration: 0,
            usage: %{input_tokens: 0, output_tokens: 0},
            cost_usd: nil,
            transcript_tail: [],
            # Final summary the worker contributed to its parent (or the
            # failure digest of what it learned before stopping).
            result: nil,
            # Content of the PARENT's todo item this agent works on — the
            # model references todos by content (it never sees runtime ids);
            # the coordinator resolves content → id at completion time.
            linked_todo: nil,
            # Untruncated-ish prompt text kept for fuzzy todo matching
            # (prompt_summary is display-truncated and too lossy to match on).
            match_text: nil,
            started_at: nil,
            finished_at: nil

  @type t :: %__MODULE__{}

  @terminal [:done, :failed, :timeout]

  @doc "Create the info record for a newly observed agent."
  @spec new(term(), map()) :: t()
  def new(id, attrs \\ %{}) do
    %__MODULE__{
      id: id,
      name: Map.get(attrs, :name),
      prompt_summary: attrs |> Map.get(:prompt_summary) |> truncate(@summary_max_chars),
      linked_todo: Map.get(attrs, :linked_todo),
      match_text: attrs |> Map.get(:match_text) |> truncate(600),
      started_at: System.system_time(:millisecond)
    }
  end

  # ── Event reducer ──────────────────────────────────────────────────

  @doc "Fold one loop event into the agent's observable state."
  @spec apply_event(t(), term()) :: t()
  # The final summary/failure digest arrives AFTER the worker's own {:done}
  # event has already made the status terminal — so it must bypass the
  # terminal guard below.
  def apply_event(info, {:result_note, text}) when is_binary(text) do
    %{info | result: truncate(text, 600)}
  end

  def apply_event(%__MODULE__{status: status} = info, _event) when status in @terminal, do: info

  def apply_event(info, {:iteration, n}) do
    %{info | iteration: n, current_action: "thinking…"}
  end

  def apply_event(info, {:content, text}) when is_binary(text) do
    append_transcript(info, {:content, text})
  end

  def apply_event(info, {:thinking, text}) when is_binary(text) do
    info
    |> Map.put(:current_action, "thinking…")
    |> append_transcript({:thinking, text})
  end

  def apply_event(info, {:tool_call, %ToolCall{} = tc}) do
    info
    |> Map.put(:current_action, "tool: #{tc.name}")
    |> append_transcript({:tool_call, "#{tc.name} #{inspect(tc.arguments)}"})
  end

  def apply_event(info, {:tool_result, %ToolResult{} = tr}) do
    info
    |> Map.put(:current_action, nil)
    |> append_transcript({:tool_result, to_string(tr.content || "")})
  end

  def apply_event(info, {:queue_wait, %{status: :waiting}}) do
    %{info | status: :waiting_gpu, current_action: "waiting for a GPU slot"}
  end

  def apply_event(info, {:queue_wait, %{status: :acquired}}) do
    %{info | status: :running, current_action: "thinking…"}
  end

  def apply_event(info, {:usage, usage}) when is_map(usage) do
    folded = %{
      input_tokens: info.usage.input_tokens + (usage[:input_tokens] || 0),
      output_tokens: info.usage.output_tokens + (usage[:output_tokens] || 0)
    }

    %{info | usage: folded}
  end

  def apply_event(info, {:conclusion, %{text: text} = entry}) do
    # Magentic-One-style stall signal, computed in code: the same STATED
    # conclusion twice in a row means the agent is spinning. Identical
    # DERIVED texts ("ran bash") are weak evidence — a busy worker yields
    # them every turn while each call differs — so those only count when
    # the underlying tool calls were identical too (fingerprint semantics).
    repeated? =
      case List.last(info.conclusions) do
        %{text: ^text, source: prev_source} ->
          if entry.source == :derived and prev_source == :derived do
            repeated_tool_call?(info)
          else
            true
          end

        _ ->
          false
      end

    %{
      info
      | conclusions: Enum.take(info.conclusions ++ [entry], -@conclusions_cap),
        status: if(repeated?, do: :stalling, else: :running)
    }
  end

  def apply_event(info, {:todos, todos}) when is_list(todos), do: set_todos(info, todos)

  def apply_event(info, {:done, %Result{} = result}) do
    status = if Result.success?(result), do: :done, else: :failed

    # A done agent can't have "in progress" sub-todos — finalize stale
    # mid-flight items on success. A failed close keeps the true state.
    todos =
      if status == :done do
        Enum.map(info.todos, fn
          %{status: :in_progress} = todo -> %{todo | status: :completed}
          todo -> todo
        end)
      else
        info.todos
      end

    %{
      info
      | status: status,
        todos: todos,
        current_action: nil,
        cost_usd: result.cost_usd || info.cost_usd,
        finished_at: System.system_time(:millisecond)
    }
  end

  def apply_event(info, {:error, reason}) do
    append_transcript(info, {:error, inspect(reason)})
  end

  def apply_event(info, _event), do: info

  @doc """
  Mark a non-terminal agent failed (the run process died underneath it).
  Terminal statuses stay as they are.
  """
  @spec fail(t()) :: t()
  def fail(%__MODULE__{status: status} = info) when status in @terminal, do: info

  def fail(info),
    do: %{
      info
      | status: :failed,
        current_action: nil,
        finished_at: System.system_time(:millisecond)
    }

  # ── Todo ledger ────────────────────────────────────────────────────

  @doc """
  Apply a full todo-list rewrite from the model, diffing against the current
  ledger to keep ids stable (matched by content) and enforcing the
  single-`in_progress` invariant.
  """
  @spec set_todos(t(), [map()]) :: t()
  def set_todos(info, raw_todos) when is_list(raw_todos) do
    {todos, next_id} = assign_ids(raw_todos, info.todos, info.next_todo_id)

    # Small models rewrite the list with only the REMAINING work, silently
    # erasing finished tasks (and orphaning their done workers in the tree).
    # Completed items missing from a rewrite are retained, in their original
    # order, ahead of the new list. Pending items may be dropped (pruning).
    rewritten = MapSet.new(todos, & &1.content)

    kept_history =
      Enum.filter(info.todos, fn todo ->
        todo.status == :completed and not MapSet.member?(rewritten, todo.content)
      end)

    %{info | todos: enforce_single_in_progress(kept_history ++ todos), next_todo_id: next_id}
  end

  @doc "Flip one todo to completed by id (runtime-derived completion)."
  @spec complete_todo(t(), pos_integer()) :: t()
  def complete_todo(info, todo_id) do
    todos =
      Enum.map(info.todos, fn
        %{id: ^todo_id} = todo -> %{todo | status: :completed}
        todo -> todo
      end)

    %{info | todos: todos}
  end

  @doc "Flip the todo matching `content` to completed (model-facing linkage)."
  @spec complete_todo_by_content(t(), String.t()) :: t()
  def complete_todo_by_content(info, content) when is_binary(content) do
    case Enum.find(info.todos, &(&1.content == content)) do
      nil -> info
      todo -> complete_todo(info, todo.id)
    end
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp assign_ids(raw_todos, existing, next_id) do
    {todos, _remaining, next_id} =
      Enum.reduce(raw_todos, {[], existing, next_id}, fn raw, {acc, remaining, next} ->
        content = field(raw, :content) || ""

        case Enum.split_with(remaining, &(&1.content == content)) do
          {[match | rest_matches], others} ->
            todo = build_todo(match.id, raw, content)
            {[todo | acc], rest_matches ++ others, next}

          {[], _others} ->
            todo = build_todo(next, raw, content)
            {[todo | acc], remaining, next + 1}
        end
      end)

    {Enum.reverse(todos), next_id}
  end

  defp build_todo(id, raw, content) do
    %{
      id: id,
      content: content,
      status: normalize_status(field(raw, :status)),
      active_form: field(raw, :activeForm) || field(raw, :active_form)
    }
  end

  defp field(raw, key) when is_map(raw), do: Map.get(raw, key) || Map.get(raw, to_string(key))

  defp normalize_status("in_progress"), do: :in_progress
  defp normalize_status("completed"), do: :completed
  defp normalize_status(:in_progress), do: :in_progress
  defp normalize_status(:completed), do: :completed
  defp normalize_status(_), do: :pending

  defp enforce_single_in_progress(todos) do
    {todos, _seen?} =
      Enum.map_reduce(todos, false, fn todo, seen? ->
        case {todo.status, seen?} do
          {:in_progress, true} -> {%{todo | status: :pending}, true}
          {:in_progress, false} -> {todo, true}
          _ -> {todo, seen?}
        end
      end)

    todos
  end

  # The last two tool calls in the transcript tail are byte-identical
  # (same name + args) — the agent is literally repeating itself.
  defp repeated_tool_call?(info) do
    case info.transcript_tail |> Enum.filter(&match?({:tool_call, _}, &1)) |> Enum.take(-2) do
      [{:tool_call, same}, {:tool_call, same}] -> true
      _ -> false
    end
  end

  # Streaming deltas arrive word-by-word — consecutive thinking/content
  # chunks COALESCE into one chat-like block instead of one row per delta.
  # Tool entries always stand alone (they break a text run).
  defp append_transcript(info, {kind, text}) when kind in [:thinking, :content] do
    case List.last(info.transcript_tail) do
      {^kind, prev} ->
        merged = truncate(prev <> text, @transcript_text_max_chars)
        tail = List.replace_at(info.transcript_tail, -1, {kind, merged})
        %{info | transcript_tail: tail}

      _ ->
        push_transcript(info, {kind, truncate(text, @transcript_text_max_chars)})
    end
  end

  defp append_transcript(info, {kind, text}) do
    push_transcript(info, {kind, truncate(text, @transcript_entry_max_chars)})
  end

  defp push_transcript(info, entry) do
    tail = Enum.take(info.transcript_tail ++ [entry], -@transcript_max_entries)
    %{info | transcript_tail: tail}
  end

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
