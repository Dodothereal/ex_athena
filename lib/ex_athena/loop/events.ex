defmodule ExAthena.Loop.Events do
  @moduledoc """
  Flat, pattern-matchable event tuples the loop emits to `:on_event`.

  Event shape inspired by `ash_ai`'s `ToolLoop.stream/2` — one tuple per
  logical event, exhaustive, easy to match on in LiveView handlers, OTel
  emitters, and cost trackers. Same events feed the OpenTelemetry span
  emitter (landing in PR 4).

  Events:

    * `{:content, text}` — partial or full assistant text.
    * `{:thinking, text}` — partial or full model reasoning/thinking
      content (Anthropic `thinking` blocks, OpenAI `reasoning`
      content). Distinct from `:content` so hosts can display it
      separately (e.g. in a side pane).
    * `{:tool_call, ToolCall.t()}` — model requested a tool call.
    * `{:tool_result, ToolResult.t()}` — tool produced a result (or error).
    * `{:tool_ui, %{tool_call_id:, kind:, payload:}}` — structured UI
      payload for hosts that render rich previews (diffs, file
      contents, process output). Only emitted when a tool returns
      the `{:ok, %{llm:, ui:}}` shape; the LLM-facing string still
      flows through `:tool_result`.
    * `{:iteration, n}` — a new iteration is starting.
    * `{:compaction, %{before:, after:, reason:}}` — context compacted.
    * `{:subagent_spawn, %{id:, prompt:}}` — a sub-agent started.
    * `{:subagent_result, %{id:, text:}}` — sub-agent returned.
    * `{:conclusion, %{iteration:, text:, source:}}` — the iteration's
      one-line conclusion (see `ExAthena.Conclusions`). `source` is
      `:stated` (model used the CONCLUSION marker), `:tail` (final
      paragraph fallback), or `:derived` (synthesized from tool activity).
      Hosts render these as a progress timeline.
    * `{:queue_wait, %{provider:, status:, waited_ms?}}` — the loop's next
      provider call is blocked waiting for a request-queue slot
      (`status: :waiting`), or just obtained one after a wait
      (`status: :acquired`, with `waited_ms`). Only emitted when the call
      actually blocks — a free slot produces no events. Hosts use this to
      render a "waiting on GPU" state for runs queued behind other loops.
    * `{:usage, usage_map}` — partial usage report from the provider.
    * `{:structured_retry, %{attempt:, error:}}` — extract_structured
      retry.
    * `{:error, reason}` — non-fatal warning (the loop continues).
    * `{:submitted, deliverable}` — the model called the `finish` tool to
      declare completion. `deliverable` is the payload passed to the tool
      (`nil` when no deliverable was provided). Emitted just before
      `{:done, Result}` when `finish_reason` is `:submitted`.
    * `{:done, Result.t()}` — terminal event. Always the last event
      emitted; the Result carries the finish_reason.
  """

  alias ExAthena.Loop.FenceFilter
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result
  alias ExAthena.Streaming.Event

  @type t ::
          {:content, String.t()}
          | {:thinking, String.t()}
          | {:tool_call, ToolCall.t()}
          | {:tool_result, ToolResult.t()}
          | {:tool_ui,
             %{
               required(:tool_call_id) => String.t(),
               required(:kind) => atom(),
               required(:payload) => map()
             }}
          | {:iteration, non_neg_integer()}
          | {:compaction,
             %{
               required(:before) => integer(),
               required(:after) => integer(),
               required(:reason) => term()
             }}
          | {:subagent_spawn, %{required(:id) => term(), required(:prompt) => String.t()}}
          | {:subagent_result, %{required(:id) => term(), required(:text) => String.t()}}
          | {:conclusion,
             %{
               required(:iteration) => non_neg_integer(),
               required(:text) => String.t(),
               required(:source) => :stated | :tail | :derived
             }}
          | {:queue_wait,
             %{
               required(:provider) => atom(),
               required(:status) => :waiting | :acquired,
               optional(:waited_ms) => non_neg_integer()
             }}
          | {:usage, map()}
          | {:structured_retry,
             %{required(:attempt) => non_neg_integer(), required(:error) => term()}}
          | {:error, term()}
          | {:submitted, term()}
          | {:done, Result.t()}

  @doc """
  Build an `:on_wait` callback for `ExAthena.RequestQueue.with_slot/3` that
  translates queue-wait notifications into `{:queue_wait, …}` loop events.

  Returns `nil` when there is no `on_event` callback (with_slot treats a nil
  on_wait as "don't notify").
  """
  @spec queue_wait_emitter((t() -> term()) | nil, atom() | nil) ::
          (:waiting | {:acquired, non_neg_integer()} -> :ok) | nil
  def queue_wait_emitter(nil, _provider), do: nil
  def queue_wait_emitter(_on_event, nil), do: nil

  def queue_wait_emitter(on_event, provider) do
    fn
      :waiting ->
        emit(on_event, {:queue_wait, %{provider: provider, status: :waiting}})

      {:acquired, waited_ms} ->
        emit(
          on_event,
          {:queue_wait, %{provider: provider, status: :acquired, waited_ms: waited_ms}}
        )
    end
  end

  @doc "Emit an event via the supplied callback (nil is a no-op)."
  @spec emit((t() -> term()) | nil, t()) :: :ok
  def emit(nil, _event), do: :ok

  def emit(callback, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end

  @doc """
  Build a `{callback, counters}` pair that translates provider-side
  `ExAthena.Streaming.Event` structs into host-side Loop event tuples.

  Providers speak `%Streaming.Event{}` structs; host UIs speak flat Loop
  tuples like `{:content, text}` and `{:thinking, text}`. This callback
  bridges the two so modes can wire a provider stream directly to an
  `on_event` callback without manually pattern-matching every event type.

  The returned `counters` (an `:counters` table with 2 slots) track how many
  text/thinking deltas have been forwarded:

    * Slot 1 — text delta count
    * Slot 2 — thinking delta count

  Modes use these counters to suppress their end-of-turn full-text emission
  when streaming deltas have already been delivered to the host, avoiding
  duplicate content.

  ## Mapping

    * `:text_delta` with binary data → increments slot 1, emits `{:content, t}`
    * `:thinking_delta` with binary data → increments slot 2, emits `{:thinking, t}`
    * `:tool_call_end` when `forward_tool_events: true` → emits `{:tool_call, data}`
    * `:tool_result` when `forward_tool_events: true` → emits `{:tool_result, data}`
    * All other events (`:start`, `:stop`, `:usage`, `:error`,
      `:tool_call_start`, `:tool_call_delta`, and tool events when forwarding
      is off) → `:ok`, nothing emitted, counters untouched

  `:usage` is intentionally dropped here because modes emit it once from the
  final `Response` struct, which has complete accounting. `:tool_call_start`
  and `:tool_call_delta` are dropped because hosts receive complete tool
  events via `:tool_call`.

  ## Options

    * `:forward_tool_events` (boolean, default `false`) — when `true`, forwards
      `:tool_call_end` and `:tool_result` events to the host callback.
    * `:filter_tool_fences` (boolean, default `false`) — when `true`, text
      deltas are run through `ExAthena.Loop.FenceFilter` so `~~~tool_call`
      fenced blocks (the TextTagged protocol used by non-native-tool-call
      providers) never reach the host as visible `{:content, _}` text; the
      loop surfaces the parsed calls as `{:tool_call, _}` events instead.
      `{:content, visible}` is emitted only when the filtered text is
      non-empty, but counter slot 1 still increments on every raw text
      delta — the end-of-turn full-text suppression must stay armed because
      the full `response.text` may also contain fences. On `:stop` the
      filter is flushed and any held tail is emitted as `{:content, tail}`
      (`:stop` itself remains untranslated). Filter state lives in the
      process dictionary under a per-callback unique key; this relies on
      the provider invoking the callback synchronously from a single
      process (mock, req_llm, and claude_code all reduce the stream
      in-process). `:thinking_delta` is never filtered.

  ## Examples

      parent = self()
      on_event = fn event -> send(parent, {:evt, event}) end
      {cb, counters} = Events.provider_stream_callback(on_event)
      cb.(%Streaming.Event{type: :text_delta, data: "hello"})
      # => {:content, "hello"} emitted; :counters.get(counters, 1) == 1

  """
  @spec provider_stream_callback((t() -> term()) | nil) ::
          {(Event.t() -> :ok), :counters.counters_ref()}
  def provider_stream_callback(on_event), do: provider_stream_callback(on_event, [])

  @spec provider_stream_callback((t() -> term()) | nil, keyword()) ::
          {(Event.t() -> :ok), :counters.counters_ref()}
  def provider_stream_callback(on_event, opts) do
    counters = :counters.new(2, [])
    forward_tools = Keyword.get(opts, :forward_tool_events, false)

    # Fence-filter state is threaded through the process dictionary because
    # the callback is 1-arity (no state slot). Safe: every provider invokes
    # the callback synchronously from a single process. The key is unique
    # per callback instance so concurrent loops in one process can't clash.
    fence_key =
      if Keyword.get(opts, :filter_tool_fences, false),
        do: {__MODULE__, :fence_filter, make_ref()}

    callback = fn
      %Event{type: :text_delta, data: t} when is_binary(t) ->
        :counters.add(counters, 1, 1)
        emit_text(on_event, t, fence_key)

      %Event{type: :thinking_delta, data: t} when is_binary(t) ->
        :counters.add(counters, 2, 1)
        emit(on_event, {:thinking, t})

      %Event{type: :tool_call_end, data: tc} when forward_tools ->
        emit(on_event, {:tool_call, tc})

      %Event{type: :tool_result, data: tr} when forward_tools ->
        emit(on_event, {:tool_result, tr})

      %Event{type: :stop} when fence_key != nil ->
        flush_fence_filter(on_event, fence_key)

      %Event{} ->
        :ok
    end

    {callback, counters}
  end

  # Unfiltered path: forward the raw delta.
  defp emit_text(on_event, text, nil), do: emit(on_event, {:content, text})

  # Filtered path: strip ~~~tool_call fences; emit only non-empty residue.
  defp emit_text(on_event, text, fence_key) do
    filter = Process.get(fence_key) || FenceFilter.new()
    {filter, visible} = FenceFilter.push(filter, text)
    Process.put(fence_key, filter)

    if visible == "", do: :ok, else: emit(on_event, {:content, visible})
  end

  # End of stream: release any held text that never became a fence, then
  # drop the per-stream filter state from the process dictionary.
  defp flush_fence_filter(on_event, fence_key) do
    case Process.delete(fence_key) do
      nil ->
        :ok

      filter ->
        case FenceFilter.flush(filter) do
          "" -> :ok
          tail -> emit(on_event, {:content, tail})
        end
    end
  end
end
