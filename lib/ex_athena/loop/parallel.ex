defmodule ExAthena.Loop.Parallel do
  @moduledoc """
  Parallel tool-call dispatcher.

  When a model emits multiple tool calls in a single response, the kernel
  groups them:

    * **Read-only calls** (tool's `parallel_safe?/0` returns `true`) run
      concurrently via `Task.async_stream/3`.
    * **Mutating calls** run serially in the order the model emitted them,
      to preserve deterministic side-effect ordering.

  Regardless of execution order, results are returned in the same order as
  the input tool calls — the model always sees results aligned with its
  calls.
  """

  alias ExAthena.{Hooks, Permissions}
  alias ExAthena.Loop.Events
  alias ExAthena.Messages
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Tools

  @doc """
  Execute a list of tool calls.

  `runner_fn` is `(ToolCall.t(), state -> {result, updated_state})`. The
  `result` is whatever the single-call runner returns (typically a
  tool-result message tuple or a `:halt` tuple). Updated state threads the
  phase transitions, mistake counter, and budget.

  Returns `{:ok, results_in_order, final_state}` or
  `{:halt, reason, final_state}` when any call returns a halt.

  Ordering guarantee: `results_in_order` is ordered the same as the input
  `calls`, even though parallel-safe calls may execute out-of-order.
  """
  @spec run([ToolCall.t()], map(), (ToolCall.t(), map() -> {term(), map()})) ::
          {:ok, [term()], map()} | {:halt, term(), map()}
  def run(calls, state, runner_fn) do
    {parallel_safe, must_serial} = classify(calls, state.tool_specs)

    # Mutations first, in order, so the filesystem state parallel tools see
    # (if any) is the post-mutation state. This matches what a human would
    # do when the model says "write file X; then grep it".
    case run_serial(must_serial, state, runner_fn) do
      {:ok, serial_results, state} ->
        case run_concurrent(parallel_safe, state, runner_fn) do
          {:ok, parallel_results, state} ->
            merged = merge_in_order(calls, serial_results ++ parallel_results)
            {:ok, merged, state}

          {:halt, _reason, _state} = halt ->
            halt
        end

      {:halt, _reason, _state} = halt ->
        halt
    end
  end

  # ── Classification ────────────────────────────────────────────────

  defp classify(calls, tool_specs) do
    Enum.split_with(calls, fn call ->
      case Tools.find(tool_specs, call.name) do
        nil -> false
        spec -> ExAthena.Tool.Spec.parallel_safe?(spec)
      end
    end)
  end

  # ── Serial execution ──────────────────────────────────────────────

  defp run_serial(calls, state, runner_fn) do
    Enum.reduce_while(calls, {:ok, [], state}, fn call, {:ok, acc, state} ->
      case runner_fn.(call, state) do
        {{:halt, reason}, new_state} -> {:halt, {:halt, reason, new_state}}
        {result, new_state} -> {:cont, {:ok, acc ++ [{call.id, result}], new_state}}
      end
    end)
  end

  # ── Parallel execution ────────────────────────────────────────────

  defp run_concurrent([], state, _runner_fn), do: {:ok, [], state}

  defp run_concurrent(calls, state, runner_fn) do
    concurrency = max(1, state.max_concurrency || 4)
    timeout = state.tool_timeout_ms || 60_000

    # Snapshot the state each task reads. Tasks do NOT mutate shared state —
    # their `runner_fn` returns per-call state deltas we fold back in order
    # afterwards. This avoids race conditions on things like the mistake
    # counter, which we'd otherwise see interleaved.
    calls
    |> Task.async_stream(
      fn call -> {call.id, runner_fn.(call, state)} end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce_while({:ok, [], state}, fn
      {:ok, {call_id, {{:halt, reason}, _new_state}}}, {:ok, _acc, state} ->
        {:halt, {:halt, reason, fold_halt(state, call_id, reason)}}

      {:ok, {call_id, {result, deltas}}}, {:ok, acc, state} ->
        {:cont, {:ok, acc ++ [{call_id, result}], fold_deltas(state, deltas)}}

      {:exit, {reason, _}}, {:ok, acc, state} ->
        # One task crashed or timed out — surface as an error result for the
        # corresponding call but don't halt. The kernel converts it to a
        # tool-error replay message.
        err_result =
          Messages.tool_result("unknown", "parallel task failed: #{inspect(reason)}", true)

        {:cont, {:ok, acc ++ [{nil, err_result}], state}}
    end)
  end

  defp fold_halt(state, _call_id, _reason), do: state

  # Each task returns its own fresh `state`; we keep deltas that matter
  # across concurrent tasks: the budget accumulator and mistake-counter resets.
  # Bumps (counter increases) from concurrent tasks are intentionally discarded
  # to avoid double-counting; resets must propagate so a successful parallel
  # call doesn't leave a stale elevated counter.
  defp fold_deltas(state, new_state) do
    state
    |> maybe_update_budget(new_state)
    |> maybe_propagate_reset(new_state)
  end

  defp maybe_update_budget(state, %{budget: b}) when not is_nil(b), do: %{state | budget: b}
  defp maybe_update_budget(state, _), do: state

  # Retained as defense-in-depth: dormant while ReAct resets at the turn
  # boundary (no per-task state ever decreases the counter), but kept in case
  # per-call resets are reintroduced.
  defp maybe_propagate_reset(state, %{consecutive_mistakes: n})
       when n < state.consecutive_mistakes,
       do: %{state | consecutive_mistakes: n}

  defp maybe_propagate_reset(state, _), do: state

  # ── Ordering ──────────────────────────────────────────────────────

  # Results come back as `[{call_id, result}]` — one per input call. Re-sort
  # them into the original call order.
  defp merge_in_order(calls, results) do
    by_id = Map.new(results, fn {id, r} -> {id, r} end)
    Enum.map(calls, fn c -> Map.get(by_id, c.id) end)
  end

  # ── Permission/hook helpers (used by the kernel, exposed here so the
  # serial + parallel paths share one implementation) ───────────────

  @doc """
  Run the pre-tool gate (permissions + PreToolUse hooks) for a single call.

  Returns `:allow`, `{:deny, reason}`, or `{:halt, reason}`.
  """
  @spec pre_tool_gate(ToolCall.t(), map()) ::
          :allow | {:deny, term()} | {:halt, term()}
  def pre_tool_gate(%ToolCall{name: name, arguments: args, id: id}, state) do
    case Permissions.check(
           %ToolCall{id: id, name: name, arguments: args},
           state.ctx,
           state.permissions_opts
         ) do
      :allow ->
        # Hooks.run_pre_tool_use returns :ok (continue), {:deny, reason}, or
        # {:halt, reason}. Normalise :ok → :allow so the caller can match
        # on one surface.
        case Hooks.run_pre_tool_use(state.hooks, name, args, id) do
          :ok ->
            :allow

          {:deny, reason} = deny ->
            fire_permission_denied(state, name, args, id, reason)
            deny

          {:halt, _} = halt ->
            halt
        end

      {:deny, reason} = deny ->
        fire_permission_denied(state, name, args, id, reason)
        deny

      {:halt, _} = halt ->
        halt
    end
  end

  defp fire_permission_denied(state, name, args, id, reason) do
    _ =
      Hooks.run_lifecycle(state.hooks, :PermissionDenied, %{
        tool_name: name,
        tool_use_id: id,
        arguments: args,
        reason: reason
      })

    case reason do
      %Permissions.Denial{} = denial ->
        _ =
          Hooks.run_lifecycle(state.hooks, :ToolDenied, %{
            tool_name: name,
            tool_use_id: id,
            arguments: args,
            denial: denial
          })

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Emit tool-result (and tool-ui) events for a completed call.

  The matching `{:tool_call, _}` event is emitted by the single-call runner
  BEFORE gating/execution, so hosts can render a "running…" state while the
  tool works.
  """
  @spec emit_result_events(map(), ToolCall.t(), Messages.Message.t()) :: :ok
  def emit_result_events(state, %ToolCall{} = _call, tool_message) do
    case tool_message.tool_results do
      [tr | _] = trs ->
        Events.emit(state.on_event, {:tool_result, tr})

        # Emit :tool_ui after :tool_result for any tool result carrying a
        # structured payload. Hosts that don't care about UI payloads can
        # ignore the event; ones that do use it to render rich content.
        Enum.each(trs, fn
          %{ui_payload: %{kind: kind, payload: payload}, tool_call_id: id} ->
            Events.emit(
              state.on_event,
              {:tool_ui, %{tool_call_id: id, kind: kind, payload: payload}}
            )

          _ ->
            :ok
        end)

        :ok

      _ ->
        :ok
    end
  end
end
