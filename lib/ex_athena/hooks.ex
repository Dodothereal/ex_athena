defmodule ExAthena.Hooks do
  @moduledoc """
  Lifecycle hooks the loop fires at key transitions.

  Shape mirrors Claude Code's SDK so existing hook code ports cleanly:

      hooks = %{
        PreToolUse: [%{matcher: "Write|Edit", hooks: [&deny_protected_paths/2]}],
        PostToolUse: [%{matcher: "Bash", hooks: [&capture_test_output/2]}],
        Stop: [&log_stop/2]
      }

  Each hook callback receives `(input_map, tool_use_id)` and returns one of:

    * `:ok` — continue with no side effects.
    * `{:deny, reason}` — only meaningful from `PreToolUse` /
      `PermissionRequest`; deny the tool call.
    * `{:halt, reason}` — stop the loop immediately.
    * `{:inject, message_or_messages}` — append the given message
      (or list of messages) to the conversation. Useful for
      `experimental.chat.system.transform`-style context injection.
    * `{:transform, new_prompt}` — only valid from `UserPromptSubmit`;
      rewrites the incoming user prompt before it enters the loop.
    * `{:augment, text}` — only valid from `PostToolUse`; appends `text`
      to the tool result content visible to the model on the next turn.
      Multiple augments from different hooks are joined with `"\\n"`.

  Hooks are matched by `:matcher` (regex run against `tool_name`); a `nil`
  matcher or a missing `:matcher` key fires for every tool. Lifecycle-only
  events are passed as plain function lists, not wrapped in matcher maps.

  ## Catalog of supported events

    * Session: `:SessionStart`, `:SessionEnd`
    * Per-turn: `:UserPromptSubmit`, `:ChatParams`, `:PreIteration`, `:Stop`, `:StopFailure`
    * Per-tool: `:PreToolUse`, `:PostToolUse`, `:PostToolUseFailure`,
      `:PermissionRequest`, `:PermissionDenied`, `:ToolDenied`
    * Subagent: `:SubagentStart`, `:SubagentStop`
    * Compaction: `:PreCompact`, `:PreCompactStage`, `:PostCompact`
    * Notification: `:Notification`
  """

  alias ExAthena.Messages.Message

  @type matcher :: String.t() | Regex.t() | nil
  @type hook_fun :: (map(), String.t() -> term())
  @type matcher_group :: %{matcher: matcher(), hooks: [hook_fun()]}

  @type t :: %{
          optional(atom()) => [matcher_group()] | [hook_fun()]
        }

  @type lifecycle_outputs :: %{
          halt: nil | {:halt, term()},
          injects: [Message.t()],
          transform: nil | String.t()
        }

  @doc """
  Catalog of every hook event ex_athena fires today. Useful for hosts
  that want to enumerate or validate user-supplied hook tables.
  """
  @spec events() :: [atom()]
  def events do
    [
      :SessionStart,
      :SessionEnd,
      :UserPromptSubmit,
      :ChatParams,
      :PreIteration,
      :Stop,
      :StopFailure,
      :PreToolUse,
      :PostToolUse,
      :PostToolUseFailure,
      :PermissionRequest,
      :PermissionDenied,
      :ToolDenied,
      :SubagentStart,
      :SubagentStop,
      :PreCompact,
      :PreCompactStage,
      :PostCompact,
      :Notification
    ]
  end

  @doc "Fire `PreToolUse` hooks matching `tool_name`."
  @spec run_pre_tool_use(t(), String.t(), map(), String.t() | nil) ::
          :ok | {:deny, term()} | {:halt, term()}
  def run_pre_tool_use(hooks, tool_name, input, tool_use_id) do
    run_tool_phase(hooks[:PreToolUse] || [], tool_name, input, tool_use_id)
  end

  @doc """
  Fire `PostToolUse` hooks matching `tool_name`.

  Returns:
    * `:ok` — all hooks returned `:ok` (or ignored returns).
    * `{:halt, term()}` — a hook requested a hard stop; no further hooks run.
    * `{:augment, String.t()}` — one or more hooks returned `{:augment, text}`;
      multiple augments are joined with `"\\n"`. `:halt` takes priority over any
      accumulated augment text.
  """
  @spec run_post_tool_use(t(), String.t(), map(), String.t() | nil) ::
          :ok | {:halt, term()} | {:augment, String.t()}
  def run_post_tool_use(hooks, tool_name, result, tool_use_id) do
    groups = hooks[:PostToolUse] || []

    case run_tool_phase_post(groups, tool_name, result, tool_use_id) do
      {:halt, _} = halt -> halt
      {:augment, ""} -> :ok
      {:augment, text} when is_binary(text) -> {:augment, text}
      _ -> :ok
    end
  end

  @doc """
  Fire lifecycle hooks that aren't scoped to a tool (Stop, SessionStart,
  etc.). Backward-compatible: returns `:ok | {:halt, reason}` like before.
  Use `run_lifecycle_with_outputs/3` for events that may inject messages
  or transform prompts.
  """
  @spec run_lifecycle(t(), atom(), map()) :: :ok | {:halt, term()}
  def run_lifecycle(hooks, event, payload) do
    case run_lifecycle_with_outputs(hooks, event, payload) do
      %{halt: {:halt, _} = h} -> h
      _ -> :ok
    end
  end

  @doc """
  Like `run_lifecycle/3` but returns a structured outputs map so callers
  can act on `{:inject, msg}` and `{:transform, prompt}` returns. Used
  by the kernel to thread `UserPromptSubmit` transforms and
  `:inject`-driven message injection across hook events.

  Returns `%{halt:, injects:, transform:}`. `halt` short-circuits the
  remaining callbacks (denies / halts always win); `injects` accumulates
  in order; `transform` is last-write-wins.
  """
  @spec run_lifecycle_with_outputs(t(), atom(), map()) :: lifecycle_outputs()
  def run_lifecycle_with_outputs(hooks, event, payload) do
    fns = hooks[event] || []

    initial = %{halt: nil, injects: [], transform: nil}

    Enum.reduce_while(fns, initial, fn fun, acc ->
      case safe_call(fun, payload, payload[:tool_use_id] || payload[:session_id]) do
        :ok ->
          {:cont, acc}

        {:halt, _} = h ->
          {:halt, %{acc | halt: h}}

        {:inject, %Message{} = msg} ->
          {:cont, %{acc | injects: acc.injects ++ [msg]}}

        {:inject, list} when is_list(list) ->
          {:cont, %{acc | injects: acc.injects ++ list}}

        {:transform, prompt} when is_binary(prompt) ->
          {:cont, %{acc | transform: prompt}}

        _ ->
          {:cont, acc}
      end
    end)
  end

  # Pre-tool phase: supports :deny and :halt; ignores :augment.
  defp run_tool_phase(groups, tool_name, input, tool_use_id) do
    groups
    |> Enum.flat_map(fn
      %{hooks: fns} = group when is_list(fns) ->
        matcher = Map.get(group, :matcher)
        if matches?(matcher, tool_name), do: fns, else: []

      fun when is_function(fun, 2) ->
        [fun]
    end)
    |> Enum.reduce_while(:ok, fn fun, _acc ->
      case safe_call(fun, Map.put_new(input, :tool_name, tool_name), tool_use_id) do
        {:deny, _} = deny -> {:halt, deny}
        {:halt, _} = halt -> {:halt, halt}
        _ -> {:cont, :ok}
      end
    end)
  end

  # Post-tool phase: ignores :deny; accumulates :augment texts; :halt wins.
  defp run_tool_phase_post(groups, tool_name, input, tool_use_id) do
    fns =
      Enum.flat_map(groups, fn
        %{hooks: fns} = group when is_list(fns) ->
          matcher = Map.get(group, :matcher)
          if matches?(matcher, tool_name), do: fns, else: []

        fun when is_function(fun, 2) ->
          [fun]
      end)

    Enum.reduce_while(fns, {:augment, ""}, fn fun, {:augment, acc_text} ->
      case safe_call(fun, Map.put_new(input, :tool_name, tool_name), tool_use_id) do
        {:halt, _} = halt ->
          {:halt, halt}

        {:augment, text} when is_binary(text) ->
          joined = if acc_text == "", do: text, else: acc_text <> "\n" <> text
          {:cont, {:augment, joined}}

        _ ->
          {:cont, {:augment, acc_text}}
      end
    end)
  end

  defp matches?(nil, _name), do: true

  defp matches?(pattern, name) when is_binary(pattern),
    do: Regex.match?(Regex.compile!(pattern), name)

  defp matches?(%Regex{} = rx, name), do: Regex.match?(rx, name)

  defp safe_call(fun, input, tool_use_id) do
    try do
      fun.(input, tool_use_id)
    rescue
      e ->
        {:halt, {:hook_crashed, Exception.message(e)}}
    end
  end
end
