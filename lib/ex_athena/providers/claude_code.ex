defmodule ExAthena.Providers.ClaudeCode do
  @moduledoc """
  Provider that wraps the `claude_code` SDK — the local `claude` CLI driven by
  an Anthropic **subscription / OAuth token** (`CLAUDE_CODE_OAUTH_TOKEN`) or a
  logged-in CLI. **No `ANTHROPIC_API_KEY` is required.**

  Unlike the HTTP providers, the Claude Code CLI is an *autonomous coding agent*:
  it runs its own tools (Read/Edit/Bash/…) inside `:cwd` and manages its own
  conversation. So this provider treats Claude as a self-contained agent:

    * `native_tool_calls: false` — ex_athena does not execute tools for it; the
      CLI does. `Request.tools` (JSON function schemas) are not forwarded; use
      claude_code's own `:allowed_tools`/`:permission_mode` via `provider_opts`.
    * `Request.messages` are flattened to a single prompt string (the CLI owns
      multi-turn state; pass `:resume`/`:continue` via opts to continue).

  Requires the optional `:claude_code` dependency; calls guard on its presence.
  """
  @behaviour ExAthena.Provider

  alias ExAthena.{Error, Request, Response, Streaming}

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: false,
      # The Claude Code CLI is a complete agent: it runs its own tools and
      # owns the reasoning loop. ex_athena must NOT teach it the text-tagged
      # tool protocol nor execute tools for it — its tool activity streams to
      # hosts as tool events and its result text is the final answer. This
      # flag tells the loop to skip prompt augmentation and tool extraction.
      self_contained_tools: true,
      streaming: true,
      json_mode: true,
      structured_output: true,
      max_tokens: 200_000,
      supports_resume: true,
      supports_system_prompt: true,
      supports_temperature: false
    }
  end

  @impl ExAthena.Provider
  def capabilities(_opts), do: capabilities()

  @impl ExAthena.Provider
  def list_models, do: list_models(model_source())

  @doc """
  Like `list_models/0`, but with an explicit `ExAthena.Providers.ClaudeCode.ModelSource`.

  Maps the CLI's reported models down to a sorted, de-duplicated list of model
  identifier strings (dropping blanks), which is what the UI dropdown needs.
  """
  @spec list_models(module()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(source) when is_atom(source) do
    case source.supported_models() do
      {:ok, infos} when is_list(infos) ->
        models =
          infos
          |> Enum.map(&model_value/1)
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, models}

      {:error, _reason} = error ->
        error
    end
  end

  defp model_value(%{value: v}), do: v
  defp model_value(%{"value" => v}), do: v
  defp model_value(_), do: nil

  defp model_source do
    Application.get_env(
      :ex_athena,
      :claude_code_model_source,
      ExAthena.Providers.ClaudeCode.SDKModelSource
    )
  end

  @impl ExAthena.Provider
  def query(%Request{} = request, opts) do
    with :ok <- ensure_dep() do
      case ClaudeCode.query(flatten_prompt(request), build_opts(request, opts)) do
        {:ok, %ClaudeCode.Message.ResultMessage{is_error: true} = r} ->
          {:error, Error.new(:server_error, result_text(r), provider: :claude_code, raw: r)}

        {:ok, %ClaudeCode.Message.ResultMessage{} = r} ->
          {:ok, to_response(r, request)}

        {:error, %ClaudeCode.Message.ResultMessage{} = r} ->
          {:error, Error.new(:server_error, result_text(r), provider: :claude_code, raw: r)}

        {:error, reason} ->
          {:error, Error.new(:server_error, inspect(reason), provider: :claude_code, raw: reason)}
      end
    end
  end

  @impl ExAthena.Provider
  def stream(%Request{} = request, callback, opts) when is_function(callback, 1) do
    with :ok <- ensure_dep(),
         {:ok, session} <- ClaudeCode.start_link(stream_opts(request, opts)) do
      try do
        acc =
          session
          |> ClaudeCode.stream(flatten_prompt(request))
          |> Enum.reduce(%{result: nil, thinking: [], partials?: false}, fn message, acc ->
            handle_message(message, callback, acc)
          end)

        Streaming.stop(callback, finish_reason(acc.result))

        case acc.result do
          %ClaudeCode.Message.ResultMessage{} = r ->
            {:ok, to_response(r, request, thinking_text(acc))}

          _ ->
            {:ok, %Response{text: "", finish_reason: :stop, provider: :claude_code}}
        end
      after
        ClaudeCode.stop(session)
      end
    end
  end

  # ── streaming message handling ───────────────────────────────────

  # Public (but undocumented) so tests can drive the SDK-message → Streaming
  # event mapping directly without standing up a CLI session.

  # Partial messages (include_partial_messages: true) stream character-level
  # text/thinking deltas. Seeing one sets `partials?`, which suppresses the
  # re-emission of the same content from the subsequent complete
  # AssistantMessage (deltas always precede it on the wire).
  @doc false
  def handle_message(%ClaudeCode.Message.PartialAssistantMessage{} = partial, cb, acc) do
    case ClaudeCode.Message.PartialAssistantMessage.extract_text(partial) do
      {:ok, text} ->
        Streaming.text_delta(cb, text)
        %{acc | partials?: true}

      :error ->
        case ClaudeCode.Message.PartialAssistantMessage.extract_thinking(partial) do
          {:ok, t} ->
            Streaming.thinking_delta(cb, t)
            %{acc | partials?: true, thinking: [t | acc.thinking]}

          :error ->
            acc
        end
    end
  end

  def handle_message(%ClaudeCode.Message.AssistantMessage{message: %{content: content}}, cb, acc)
      when is_list(content) do
    Enum.reduce(content, acc, fn
      # Tool inputs are not reconstructible from text/thinking deltas, so tool
      # calls are always surfaced from the complete message.
      %ClaudeCode.Content.ToolUseBlock{} = b, a ->
        tool_call = %ExAthena.Messages.ToolCall{id: b.id, name: b.name, arguments: b.input}
        Streaming.tool_call_end(cb, nil, tool_call)
        a

      # Text/thinking fallback for CLIs without partial-message support; when
      # deltas streamed, skip to avoid doubling (incl. Response.thinking).
      %ClaudeCode.Content.TextBlock{text: t}, %{partials?: false} = a when is_binary(t) ->
        Streaming.text_delta(cb, t)
        a

      %ClaudeCode.Content.ThinkingBlock{thinking: t}, %{partials?: false} = a
      when is_binary(t) ->
        Streaming.thinking_delta(cb, t)
        %{a | thinking: [t | a.thinking]}

      _, a ->
        a
    end)
  end

  # The CLI executes tools itself and reports their outputs as UserMessages
  # carrying ToolResultBlocks. Surface those so hosts can render tool activity.
  def handle_message(%ClaudeCode.Message.UserMessage{message: %{content: content}}, cb, acc)
      when is_list(content) do
    Enum.each(content, fn
      %ClaudeCode.Content.ToolResultBlock{} = b ->
        Streaming.tool_result(cb, %ExAthena.Messages.ToolResult{
          tool_call_id: b.tool_use_id,
          content: flatten_result_content(b.content),
          is_error: b.is_error
        })

      _other ->
        :ok
    end)

    acc
  end

  def handle_message(%ClaudeCode.Message.ResultMessage{} = r, cb, acc) do
    Streaming.usage(cb, usage(r))
    %{acc | result: r}
  end

  def handle_message(_other, _cb, acc), do: acc

  defp flatten_result_content(content) when is_binary(content), do: content

  defp flatten_result_content(content) when is_list(content) do
    Enum.map_join(content, fn
      %ClaudeCode.Content.TextBlock{text: t} when is_binary(t) -> t
      other -> inspect(other)
    end)
  end

  defp flatten_result_content(content), do: inspect(content)

  # Accumulated thinking deltas are prepended, so reverse to restore order.
  defp thinking_text(%{thinking: []}), do: nil
  defp thinking_text(%{thinking: parts}), do: parts |> Enum.reverse() |> Enum.join("")

  # ── mapping ──────────────────────────────────────────────────────

  defp to_response(%ClaudeCode.Message.ResultMessage{} = r, %Request{} = request, thinking \\ nil) do
    %Response{
      text: r.result,
      thinking: thinking,
      tool_calls: [],
      finish_reason: finish_reason(r),
      usage: usage(r),
      model: request.model,
      provider: :claude_code,
      raw: r
    }
  end

  defp finish_reason(%ClaudeCode.Message.ResultMessage{is_error: true}), do: :error
  defp finish_reason(%ClaudeCode.Message.ResultMessage{subtype: :error_max_turns}), do: :length
  defp finish_reason(%ClaudeCode.Message.ResultMessage{}), do: :stop
  defp finish_reason(_), do: :stop

  defp usage(%ClaudeCode.Message.ResultMessage{usage: usage}) when is_map(usage) do
    %{
      input_tokens: token(usage, :input_tokens),
      output_tokens: token(usage, :output_tokens)
    }
  end

  defp usage(_), do: %{}

  defp token(usage, key) do
    Map.get(usage, key) || Map.get(usage, to_string(key)) || 0
  end

  defp result_text(%ClaudeCode.Message.ResultMessage{result: r}) when is_binary(r), do: r
  defp result_text(_), do: "claude_code error"

  # claude_code takes a single prompt string and owns conversation state.
  defp flatten_prompt(%Request{messages: messages}) do
    messages
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp message_text(%{content: content}) when is_binary(content), do: content

  defp message_text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{type: :text, text: t} -> t
      %{text: t} when is_binary(t) -> t
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp message_text(_), do: nil

  # stream/3 turns on partial messages by default for character-level deltas.
  # `put_new` runs after build_opts merged Request.provider_opts, so callers
  # can opt out via `provider_opts: [include_partial_messages: false]`.
  @doc false
  def stream_opts(%Request{} = request, opts) do
    request
    |> build_opts(opts)
    |> Keyword.put_new(:include_partial_messages, true)
  end

  # Map the supported subset of ex_athena opts → claude_code session opts. Extra
  # claude_code-specific options can be threaded via Request.provider_opts.
  @doc false
  def build_opts(%Request{} = request, opts) do
    [
      model: request.model,
      system_prompt: request.system_prompt,
      cwd: opts[:cwd],
      allowed_tools: opts[:allowed_tools],
      permission_mode: opts[:permission_mode] || phase_to_mode(opts[:phase]),
      max_turns: opts[:max_iterations] || opts[:max_turns],
      add_dir: opts[:add_dir],
      resume: opts[:resume],
      timeout: request.timeout_ms || :infinity
    ]
    |> Keyword.merge(List.wrap(request.provider_opts))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Map ex_athena's permission phase → claude_code's permission mode. The CLI is
  # an autonomous agent working in an isolated worktree, so the default is
  # `:accept_edits` (apply file edits without prompting); read-only phases stay
  # in `:plan`.
  defp phase_to_mode(:plan), do: :plan
  defp phase_to_mode(:bypass_permissions), do: :bypass_permissions
  defp phase_to_mode(:accept_edits), do: :accept_edits
  defp phase_to_mode(_), do: :accept_edits

  defp ensure_dep do
    if Code.ensure_loaded?(ClaudeCode) do
      :ok
    else
      {:error,
       Error.new(:capability, "the :claude_code dependency is not installed",
         provider: :claude_code
       )}
    end
  end
end
