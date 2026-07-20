defmodule ExAthena.Providers.ReqLLM do
  @moduledoc """
  Delegating provider that runs requests through the `req_llm` library.

  `req_llm` ships 18+ providers (OpenAI, Anthropic, Ollama, LM Studio,
  OpenRouter, Groq, Together, DeepInfra, Vercel, Mistral, Gemini, Cohere,
  Bedrock, llama.cpp, vLLM, …) with a canonical data model and `models.dev`
  cost/context metadata. ExAthena delegates to it instead of maintaining
  per-provider modules.

  ## Usage

  Callers identify a model via the `req_llm` two-part spec
  (`"provider:model-id"` or a `{provider, model_id}` tuple):

      ExAthena.query("hi",
        provider: :req_llm,
        model: "ollama:llama3.1",
        base_url: "http://localhost:11434"
      )

      ExAthena.query("hi",
        provider: :req_llm,
        model: "anthropic:claude-opus-4-8",
        api_key: System.get_env("ANTHROPIC_API_KEY")
      )

  The provider atoms `:ollama`, `:openai`, `:openai_compatible`, `:llamacpp`,
  `:claude`, `:mock` continue to route here via `ExAthena.Config` and are
  translated to the appropriate `req_llm` model spec.

  ## Capabilities

  Reported statically at `:native_tool_calls / :streaming / :json_mode`
  = true, reflecting req_llm's superset. The loop's auto-fallback handles
  individual-model quirks (e.g. Ollama models without native tool-calls).
  """

  @behaviour ExAthena.Provider

  require Logger

  alias ExAthena.{Embedding, Error, Request, Response}
  alias ExAthena.Messages.{Message, ToolResult}

  # Claude Code-style log prefix so callers can filter/tail the adapter
  # boundary independently of other ex_athena components.
  @log_prefix "[ExAthena.ReqLLM]"

  # Per-turn completion cap (distinct from the context window). Generous
  # enough for a full thinking block + answer; prevents one runaway turn
  # from eating the whole context.
  @default_completion_tokens 8_192

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: true,
      streaming: true,
      json_mode: true,
      embeddings: true,
      structured_output: true,
      # Context-window fallback when the server doesn't report one. 8k made
      # compaction fire destructively at ~5k tokens on 32k+ local models;
      # every 2024+ local model serves ≥32k.
      max_tokens: 32_768,
      supports_resume: false,
      supports_system_prompt: true,
      supports_temperature: true,
      compact_tool_schemas: true
    }
  end

  @impl ExAthena.Provider
  def capabilities(opts) do
    base = capabilities()

    case resolve_llmdb_context(opts) do
      {:ok, context} ->
        %{base | max_tokens: context}

      :error ->
        case ExAthena.ContextWindow.lookup(opts) do
          {:ok, context} -> %{base | max_tokens: context}
          :error -> base
        end
    end
  end

  @impl ExAthena.Provider
  def query(%Request{} = request, opts) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts),
         :ok <- ensure_exo_instance(request, opts) do
      log_request(:query, model_spec, request, messages, req_opts)

      case ReqLLM.generate_text(model_spec, messages, req_opts) do
        {:ok, %ReqLLM.Response{} = resp} ->
          response = to_response(resp, request)
          log_response(response)
          {:ok, response}

        {:error, reason} ->
          log_error(reason)
          {:error, to_error(reason)}
      end
    end
  end

  @impl ExAthena.Provider
  def stream(%Request{} = request, callback, opts) when is_function(callback, 1) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts),
         :ok <- ensure_exo_instance(request, opts) do
      log_request(:stream, model_spec, request, messages, req_opts)

      case ReqLLM.stream_text(model_spec, messages, req_opts) do
        {:ok, %ReqLLM.StreamResponse{} = sr} ->
          case consume_stream(sr, callback, request) do
            {:ok, response} ->
              log_response(response)
              {:ok, response}

            {:error, _} = err ->
              err
          end

        {:error, reason} ->
          log_error(reason)
          {:error, to_error(reason)}
      end
    end
  end

  # ── Embeddings ────────────────────────────────────────────────────
  #
  # req_llm 1.10 already ships an embeddings path (`ReqLLM.embed/3` → POST
  # `<base_url>/embeddings`), so ExAthena rides it instead of hand-rolling
  # Ollama's native `/api/embed`: every OpenAI-wire-compatible backend
  # (Ollama's `/v1/embeddings`, OpenAI, Gemini, OpenRouter, …) is covered by
  # the same adapter, with the same base_url/api_key plumbing as chat.

  @impl ExAthena.Provider
  def embed(input, opts) do
    with {:ok, model_spec} <- resolve_embedding_model(opts) do
      req_opts = build_embed_opts(opts)

      Logger.info(
        "#{@log_prefix} →embed model=#{model_id(model_spec)} inputs=#{length(List.wrap(input))}"
      )

      case ReqLLM.embed(model_spec, input, req_opts) do
        {:ok, %{embedding: vectors, usage: usage}} ->
          {:ok,
           %Embedding{
             embeddings: normalize_vectors(vectors),
             model: model_id(model_spec),
             provider: :req_llm,
             usage: usage,
             raw: vectors
           }}

        {:error, reason} ->
          log_error(reason)
          {:error, to_error(reason)}
      end
    end
  end

  # A single string yields a single vector; ExAthena.Embedding always exposes
  # a list of vectors so callers never branch on input arity.
  defp normalize_vectors([first | _] = vectors) when is_list(first), do: vectors
  defp normalize_vectors(vector) when is_list(vector), do: [vector]

  defp model_id(%LLMDB.Model{} = model), do: model.provider_model_id || model.id
  defp model_id(spec) when is_binary(spec), do: spec

  defp resolve_embedding_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        {:ok, embedding_model_spec(model, opts)}

      _ ->
        {:error, Error.new(:bad_request, "no embedding model configured", provider: :req_llm)}
    end
  end

  # req_llm rejects any model whose catalog entry (or id) doesn't advertise
  # embeddings — which is every local embedding model, since `nomic-embed-text`
  # is absent from llm_db and doesn't contain the literal "embedding". Declare
  # the capability inline: the caller asked to embed with this model, and only
  # the server can say whether it can.
  defp embedding_model_spec(model, opts) do
    case Keyword.get(opts, :req_llm_provider_tag) do
      tag when is_binary(tag) and tag != "" ->
        ReqLLM.model!(%{
          provider: String.to_existing_atom(tag),
          id: strip_tag_prefix(model, tag),
          capabilities: %{embeddings: true}
        })

      _ ->
        model
    end
  end

  defp build_embed_opts(opts) do
    backend = Keyword.get(opts, :openai_compatible_backend)

    base_opts =
      [
        api_key: resolve_api_key(Keyword.get(opts, :api_key), backend),
        base_url: normalize_base_url(Keyword.get(opts, :base_url), backend),
        dimensions: Keyword.get(opts, :dimensions),
        # Usage is free here (the response carries it) and indexing jobs need
        # it to budget large runs.
        return_usage: true
      ]
      |> Keyword.reject(fn {_k, v} -> is_nil(v) or v == [] end)

    base_opts
    |> Keyword.merge(Keyword.get(opts, :provider_opts, []))
    |> fold_extra_headers(Keyword.get(opts, :extra_headers))
    |> put_embed_timeout(Keyword.get(opts, :timeout_ms))
  end

  # The embedding option schema is narrower than the chat one and rejects a
  # top-level `:receive_timeout`; `prepare_embedding_request/4` instead splices
  # `:req_http_options` straight into `Req.new/1`, so the timeout rides there.
  defp put_embed_timeout(opts, nil), do: opts

  defp put_embed_timeout(opts, timeout_ms) when is_integer(timeout_ms) do
    http_opts =
      opts
      |> Keyword.get(:req_http_options, [])
      |> Keyword.put_new(:receive_timeout, timeout_ms)

    Keyword.put(opts, :req_http_options, http_opts)
  end

  # ── Model resolution ──────────────────────────────────────────────

  # Translate ExAthena-side provider atoms into req_llm model specs.
  # Callers may pass a two-part string (`"openai:gpt-4"`) OR a bare model
  # id (`"qwen2.5-coder:14b"`). When bare, Config threads the provider's
  # `req_llm` tag through opts so we can build the full spec here.
  #
  # When a tag is available, materialize the spec via `ReqLLM.model!/1` with
  # the map form (`%{provider: :openai, id: "..."}`). This goes through
  # req_llm's inline-spec path, which skips the `IO.warn "Using unverified
  # model: ..."` that fires for catalog misses on non-listed model ids
  # (Ollama's `gemma:7b`, custom local models, etc.).
  #
  # Note: bare Ollama model ids legitimately contain `:` (the version
  # separator, e.g. `"qwen2.5-coder:14b"`) so we cannot use the presence
  # of a colon as a "spec already tagged" signal — the tag is the source
  # of truth. We only strip when the model string already begins with the
  # same tag (caller passed a fully-formed spec).
  @doc false
  def resolve_model(%Request{model: model_str}, opts)
      when is_binary(model_str) and model_str != "" do
    {:ok, build_model_spec(model_str, opts)}
  end

  def resolve_model(_request, opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        {:ok, build_model_spec(m, opts)}

      _ ->
        {:error, Error.new(:bad_request, "no model configured", provider: :req_llm)}
    end
  end

  defp build_model_spec(model, opts) do
    case Keyword.get(opts, :req_llm_provider_tag) do
      tag when is_binary(tag) and tag != "" ->
        prefix = tag <> ":"

        id =
          if String.starts_with?(model, prefix),
            do: String.replace_prefix(model, prefix, ""),
            else: model

        ReqLLM.model!(%{provider: String.to_existing_atom(tag), id: id})

      _ ->
        model
    end
  end

  # ── Messages ──────────────────────────────────────────────────────

  defp build_messages(%Request{messages: [], system_prompt: sp})
       when is_binary(sp) and sp != "" do
    # System-prompt-only request — req_llm requires at least one user msg.
    {:error, Error.new(:bad_request, "no messages supplied", provider: :req_llm)}
  end

  defp build_messages(%Request{messages: messages, system_prompt: sp}) do
    base =
      case sp do
        nil -> []
        "" -> []
        str -> [%ReqLLM.Message{role: :system, content: [ReqLLM.Message.ContentPart.text(str)]}]
      end

    converted = messages |> apply_rolling_reasoning() |> Enum.map(&to_req_llm_message/1)
    {:ok, base ++ converted}
  end

  @doc false
  # Rolling-checkpoint reasoning replay (June-2026 consensus — Qwen3+
  # template behavior, DeepSeek/MiniMax/Kimi/Anthropic guidance): reasoning
  # is replayed for assistant messages WITHIN the current tool loop (after
  # the last user message) and dropped for completed turns. req_llm's
  # OpenAI encoder drops :thinking parts outbound, so replay re-injects the
  # verbatim reasoning inline as <think> in the content — the
  # deepseek-legacy / MiniMax inline convention; templates that don't want
  # it prune it. Withholding is the lossy direction.
  def apply_rolling_reasoning(messages) do
    # Window = exactly ONE turn: only the LAST assistant message replays
    # its reasoning (the interleaved-thinking minimum every vendor needs).
    # An "after the last user message" window is unbounded in agent loops —
    # there is one user message, so every turn's reasoning accumulated
    # forever (observed live as useless context growth).
    last_assistant_idx =
      messages
      |> Enum.with_index()
      |> Enum.reduce(-1, fn
        {%Message{role: :assistant}, idx}, _acc -> idx
        _, acc -> acc
      end)

    messages
    |> Enum.with_index()
    |> Enum.map(fn
      {%Message{role: :assistant, reasoning: r} = msg, idx}
      when is_binary(r) and r != "" and idx == last_assistant_idx ->
        %{msg | content: "<think>\n#{r}\n</think>\n\n#{msg.content || ""}"}

      {msg, _idx} ->
        msg
    end)
  end

  @doc false
  def to_req_llm_message(%Message{role: :system, content: content}) do
    %ReqLLM.Message{role: :system, content: text_parts(content)}
  end

  def to_req_llm_message(%Message{role: :user, content: content}) do
    %ReqLLM.Message{role: :user, content: text_parts(content)}
  end

  def to_req_llm_message(%Message{role: :assistant, content: content, tool_calls: calls}) do
    %ReqLLM.Message{
      role: :assistant,
      content: text_parts(content),
      tool_calls: if(is_list(calls) and calls != [], do: format_tool_calls(calls), else: nil)
    }
  end

  def to_req_llm_message(%Message{role: :tool, tool_results: [%ToolResult{} = first | _]}) do
    %ReqLLM.Message{
      role: :tool,
      content: text_parts(first.content),
      tool_call_id: first.tool_call_id,
      metadata: if(first.is_error, do: %{is_error: true}, else: %{})
    }
  end

  def to_req_llm_message(%Message{role: :tool, content: content}) when is_binary(content) do
    # Older shape — no tool_call_id available; forward as user-visible text.
    %ReqLLM.Message{role: :user, content: text_parts(content)}
  end

  defp text_parts(nil), do: []
  defp text_parts(""), do: []

  defp text_parts(content) when is_binary(content),
    do: [ReqLLM.Message.ContentPart.text(content)]

  defp text_parts(parts) when is_list(parts),
    do: Enum.map(parts, &to_req_llm_content_part/1)

  defp to_req_llm_content_part(%ExAthena.Messages.ContentPart{type: :text, text: text}),
    do: ReqLLM.Message.ContentPart.text(text)

  defp to_req_llm_content_part(%ExAthena.Messages.ContentPart{
         type: :image,
         data: data,
         media_type: media_type
       }),
       do: ReqLLM.Message.ContentPart.image(data, media_type)

  defp to_req_llm_content_part(%ExAthena.Messages.ContentPart{type: :image_url, url: url}),
    do: ReqLLM.Message.ContentPart.image_url(url)

  defp to_req_llm_content_part(%ExAthena.Messages.ContentPart{
         type: :file,
         data: data,
         filename: filename,
         media_type: media_type
       }),
       do: ReqLLM.Message.ContentPart.file(data, filename, media_type)

  defp format_tool_calls(calls) do
    Enum.map(calls, fn tc ->
      ReqLLM.ToolCall.new(tc.id, tc.name, encode_arguments(tc.arguments))
    end)
  end

  defp encode_arguments(nil), do: "{}"
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(args) when is_map(args), do: Jason.encode!(args)

  defp encode_arguments(args),
    do: raise(ArgumentError, "unexpected tool_call arguments type: #{inspect(args)}")

  # ── Options ────────────────────────────────────────────────────────

  @doc false
  def build_opts(%Request{} = request, opts) do
    backend = Keyword.get(opts, :openai_compatible_backend)
    base_url = normalize_base_url(Keyword.get(opts, :base_url), backend)
    api_key = resolve_api_key(Keyword.get(opts, :api_key), backend)

    # req_llm's OpenAI provider only accepts :ollama / "ollama" as
    # openai_compatible_backend. For llamacpp we handle auth via a synthetic
    # api_key, so we must not forward the backend marker to req_llm.
    req_llm_backend = if backend in [:ollama, "ollama"], do: backend, else: nil

    base_opts =
      [
        api_key: api_key,
        base_url: base_url,
        openai_compatible_backend: req_llm_backend,
        # Completion cap (NOT the context window): unbounded per-turn output
        # lets a thinking model ramble a whole context away in one turn.
        max_tokens: request.max_tokens || @default_completion_tokens,
        # Qwen's official thinking/coding profile (0.6/0.95) — never greedy
        # (official guidance: greedy causes "endless repetitions"), never
        # server-default-hot. Explicit request values always win.
        temperature: request.temperature || 0.6,
        top_p: request.top_p || 0.95,
        stop: request.stop,
        tools: to_req_llm_tools(request.tools),
        tool_choice: request.tool_choice,
        response_format: Keyword.get(opts, :response_format, request.response_format),
        receive_timeout: request.timeout_ms
      ]
      |> Keyword.reject(fn {_k, v} -> is_nil(v) or v == [] end)

    provider_opts = Keyword.get(opts, :provider_opts, [])
    merged = Keyword.merge(base_opts, provider_opts)
    merged = fold_extra_headers(merged, Keyword.get(opts, :extra_headers))
    {:ok, merged}
  end

  # Converts a string-to-string map of extra headers into the `req_http_options`
  # keyword list that req_llm uses to inject headers into Req requests.
  defp fold_extra_headers(opts, nil), do: opts
  defp fold_extra_headers(opts, headers) when is_map(headers) and map_size(headers) == 0, do: opts

  defp fold_extra_headers(opts, headers) when is_map(headers) do
    header_list = Enum.map(headers, fn {k, v} -> {k, v} end)
    existing_http_opts = Keyword.get(opts, :req_http_options, [])
    existing_headers = Keyword.get(existing_http_opts, :headers, [])
    merged_headers = existing_headers ++ header_list
    merged_http_opts = Keyword.put(existing_http_opts, :headers, merged_headers)
    Keyword.put(opts, :req_http_options, merged_http_opts)
  end

  # ex_athena's modes (see `Tools.describe_for_provider/1`) build OpenAI-format
  # tool maps (`%{type: "function", function: %{name, description, parameters}}`)
  # directly. req_llm 1.10 expects each entry in `:tools` to be a `%ReqLLM.Tool{}`
  # struct so it can call `ReqLLM.Tool.to_schema/2` per provider — passing maps
  # raises `no function clause matching in ReqLLM.Tool.to_schema/2`. Convert
  # here. The callback is a stub: req_llm uses it only for client-side execution
  # and ex_athena executes tools server-side via `ExAthena.Tool.execute/2`.
  @doc false
  def to_req_llm_tools(nil), do: nil
  def to_req_llm_tools([]), do: []
  def to_req_llm_tools(tools) when is_list(tools), do: Enum.map(tools, &to_req_llm_tool/1)

  defp to_req_llm_tool(%ReqLLM.Tool{} = tool), do: tool

  defp to_req_llm_tool(%{function: %{name: name, description: desc, parameters: params}}) do
    build_req_llm_tool(name, desc, params)
  end

  defp to_req_llm_tool(%{
         "function" => %{"name" => name, "description" => desc, "parameters" => params}
       }) do
    build_req_llm_tool(name, desc, params)
  end

  defp build_req_llm_tool(name, desc, params) do
    %ReqLLM.Tool{
      name: name,
      description: desc,
      parameter_schema: params || %{},
      callback: &noop_callback/1,
      strict: false,
      compiled: nil,
      provider_options: %{}
    }
  end

  defp noop_callback(_args),
    do: {:error, :tool_execution_handled_by_ex_athena}

  # Local OpenAI-compatible servers (Ollama, llama.cpp) commonly accept either
  # the bare host (`http://localhost:11434`) or the OpenAI prefix
  # (`http://localhost:11434/v1`). req_llm's openai adapter expects the prefix
  # to already include `/v1`. Append it when the caller passed the bare host.
  defp normalize_base_url(nil, _backend), do: nil
  defp normalize_base_url(url, nil), do: url

  defp normalize_base_url(url, _backend) when is_binary(url) do
    trimmed = String.trim_trailing(url, "/")

    cond do
      String.ends_with?(trimmed, "/v1") -> trimmed
      true -> trimmed <> "/v1"
    end
  end

  # req_llm's openai adapter requires *some* api_key value even when
  # `openai_compatible_backend: :ollama | :llamacpp` allows missing auth — the
  # underlying HTTP request still sets an Authorization header. Local servers
  # ignore it, so substitute a placeholder when the caller didn't supply one.
  defp resolve_api_key(nil, :ollama), do: "ollama"
  defp resolve_api_key(nil, :llamacpp), do: "llamacpp"
  defp resolve_api_key(nil, :exo), do: "exo"
  defp resolve_api_key(key, _backend), do: key

  # exo requires an active instance per model before chat requests succeed
  # (404 "No instance found for model …" otherwise). Activate it pre-flight;
  # ExAthena.Chat.Exo checks before placing because /place_instance is not
  # idempotent. Other backends skip this entirely. Only an explicit allowlist
  # of opts is forwarded (no unrelated provider opts leak).
  defp ensure_exo_instance(%Request{} = request, opts) do
    if Keyword.get(opts, :openai_compatible_backend) == :exo do
      model = raw_model_id(request, opts)

      # Positive presence is cached briefly — the preflight used to add an
      # HTTP GET + :global.trans to EVERY provider call in the loop. Keyed
      # by base_url + model so distinct servers never share an entry.
      cache_key = {:exo_instance_ok, Keyword.get(opts, :base_url), model}

      cached_at =
        case :persistent_term.get(cache_key, nil) do
          nil -> nil
          ts -> ts
        end

      if is_integer(cached_at) and
           System.monotonic_time(:millisecond) - cached_at < 30_000 do
        :ok
      else
        do_ensure_exo_instance(request, opts, model, cache_key)
      end
    else
      :ok
    end
  end

  defp do_ensure_exo_instance(_request, opts, model, cache_key) do
    # :timeout_ms in provider opts is the *request* timeout (UIs set it to
    # hours); the instance-await deadline must stay independent, so only
    # exo-namespaced keys override Chat.Exo's defaults (250 ms / 10 s).
    exo_opts =
      Keyword.take(opts, [:base_url]) ++
        take_renamed(opts,
          exo_poll_interval_ms: :poll_interval_ms,
          exo_instance_timeout_ms: :timeout_ms
        )

    case ExAthena.Chat.Exo.ensure_instance(model, exo_opts) do
      :ok ->
        :persistent_term.put(cache_key, System.monotonic_time(:millisecond))
        :ok

      {:error, :exo_unreachable} ->
        {:error,
         Error.new(:transport, "exo is unreachable at the configured base_url",
           provider: :req_llm,
           raw: :exo_unreachable
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :server_error,
           "exo has no active instance for #{model} (#{inspect(reason)})",
           provider: :req_llm,
           raw: reason
         )}
    end
  end

  defp take_renamed(opts, mapping) do
    for {from, to} <- mapping, {:ok, value} <- [Keyword.fetch(opts, from)], do: {to, value}
  end

  defp raw_model_id(%Request{model: model}, opts) when is_binary(model) and model != "",
    do: strip_tag_prefix(model, Keyword.get(opts, :req_llm_provider_tag))

  defp raw_model_id(_request, opts),
    do: strip_tag_prefix(Keyword.get(opts, :model), Keyword.get(opts, :req_llm_provider_tag))

  # Models may arrive tag-prefixed ("openai:mlx-community/..."); exo's API
  # wants the bare id.
  defp strip_tag_prefix(model, tag) when is_binary(model) and is_binary(tag) do
    prefix = tag <> ":"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end

  defp strip_tag_prefix(model, _tag), do: model

  # ── Response mapping ──────────────────────────────────────────────

  defp to_response(%ReqLLM.Response{} = resp, %Request{} = request) do
    thinking =
      case ReqLLM.Response.thinking(resp) do
        nil -> nil
        "" -> nil
        text -> text
      end

    # Local servers/templates sometimes leak <think> blocks (or an orphan
    # leading "…</think>") into content instead of reasoning_content —
    # the leaked CoT then persists into history, bloats every later turn,
    # and corrupts conclusions/no-progress checks. Route it to thinking.
    {text, leaked} = split_leaked_thinking(extract_text(resp))

    thinking =
      case {thinking, leaked} do
        {t, nil} -> t
        {nil, l} -> l
        {t, l} -> t <> "\n" <> l
      end

    %Response{
      text: text,
      thinking: thinking,
      tool_calls: extract_tool_calls(resp),
      finish_reason: resp.finish_reason,
      model: resp.model || request.model,
      provider: :req_llm,
      usage: resp.usage,
      raw: resp
    }
  end

  @doc false
  def split_leaked_thinking(text) when is_binary(text) do
    cond do
      String.contains?(text, "<think>") ->
        leaked =
          ~r/<think>(.*?)<\/think>/s
          |> Regex.scan(text, capture: :all_but_first)
          |> Enum.map_join("\n", fn [t] -> String.trim(t) end)

        clean = text |> String.replace(~r/<think>.*?<\/think>/s, "") |> String.trim()
        {clean, if(leaked == "", do: nil, else: leaked)}

      # Orphan close tag: the template stripped the opening <think>, so
      # everything before "</think>" is reasoning.
      String.contains?(text, "</think>") ->
        [leaked, rest] = String.split(text, "</think>", parts: 2)
        {String.trim(rest), leaked |> String.trim() |> non_empty()}

      true ->
        {text, nil}
    end
  end

  def split_leaked_thinking(other), do: {other, nil}

  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  defp extract_text(%ReqLLM.Response{message: nil}), do: ""

  defp extract_text(%ReqLLM.Response{message: %{content: content}}) when is_binary(content),
    do: content

  defp extract_text(%ReqLLM.Response{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(fn part -> part_type(part) == :text end)
    |> Enum.map_join("", &part_text/1)
  end

  defp extract_text(_), do: ""

  defp extract_tool_calls(%ReqLLM.Response{message: nil}), do: []

  defp extract_tool_calls(%ReqLLM.Response{message: %{tool_calls: calls}}) when is_list(calls) do
    case ExAthena.ToolCalls.Native.parse(calls) do
      {:ok, parsed} -> parsed
      _ -> []
    end
  end

  defp extract_tool_calls(%ReqLLM.Response{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(fn part -> part_type(part) == :tool_use end)
    |> Enum.map(&part_to_tool_call/1)
  end

  defp extract_tool_calls(_), do: []

  defp part_type(%{type: type}), do: type
  defp part_type(%{"type" => type}) when is_binary(type), do: String.to_atom(type)
  defp part_type(_), do: :unknown

  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(%{"text" => text}) when is_binary(text), do: text
  defp part_text(_), do: ""

  defp part_to_tool_call(part) do
    %ExAthena.Messages.ToolCall{
      id: Map.get(part, :id) || Map.get(part, "id"),
      name: Map.get(part, :name) || Map.get(part, "name"),
      arguments:
        Map.get(part, :input) || Map.get(part, "input") ||
          Map.get(part, :arguments) || Map.get(part, "arguments") || %{}
    }
  end

  # ── Streaming ─────────────────────────────────────────────────────

  @doc false
  # Hard ceiling on TOTAL streamed bytes (content + reasoning) per turn. The
  # `max_tokens` completion cap bounds the answer channel, but some local
  # servers (mlx/EXO) don't apply it to the *thinking* channel — a small model
  # that degenerates into repeating a phrase ("I must wait…") would then stream
  # forever and never finish a turn, so the inter-turn rails never fire. This
  # guarantees the turn terminates; the truncated turn is then handled normally.
  @stream_bytes_per_token 8

  def consume_stream(%ReqLLM.StreamResponse{stream: stream}, callback, request) do
    max_stream_bytes =
      (request.max_tokens || @default_completion_tokens) * @stream_bytes_per_token

    state = %{
      text: [],
      thinking: [],
      streamed_bytes: 0,
      tool_calls: [],
      # Collects OpenAI-style streaming tool-call argument fragments keyed by
      # the tool-call index. llama.cpp (and strict OpenAI clients) stream
      # argument JSON in separate delta chunks; Ollama sends them complete in
      # the first chunk. The buffer is empty for Ollama so it is a no-op there.
      tool_call_args_buffer: %{},
      model: request.model,
      finish_reason: nil,
      usage: nil,
      first_chunk_logged: false,
      stream_started_ms: System.monotonic_time(:millisecond)
    }

    heartbeat_pid = start_heartbeat(state.stream_started_ms)

    stream_result =
      try do
        final =
          Enum.reduce_while(stream, state, fn chunk, acc ->
            acc = maybe_log_first_chunk(chunk, acc)
            acc = handle_chunk(chunk, callback, acc)

            if acc.streamed_bytes > max_stream_bytes do
              Logger.warning(
                "#{@log_prefix} runaway stream guard tripped at #{acc.streamed_bytes}B " <>
                  "(cap #{max_stream_bytes}B) — truncating turn as :length"
              )

              {:halt, %{acc | finish_reason: acc.finish_reason || :length}}
            else
              {:cont, acc}
            end
          end)

        {:ok, final}
      rescue
        e in [ReqLLM.Error.API.Stream, Mint.TransportError, Finch.Error] ->
          Logger.warning(
            "#{@log_prefix} transport/stream error during consume: #{Exception.message(e)}"
          )

          {:error, to_error(e)}
      after
        stop_heartbeat(heartbeat_pid)
      end

    case stream_result do
      {:error, _} = err ->
        err

      {:ok, final} ->
        ExAthena.Streaming.stop(callback, final.finish_reason || :stop)

        tool_calls = patch_tool_call_args(final.tool_calls, final.tool_call_args_buffer)

        text = final.text |> Enum.reverse() |> IO.iodata_to_binary()
        thinking = final.thinking |> Enum.reverse() |> IO.iodata_to_binary()

        # Log the resolved tool calls. Warn when args are still empty after patching
        # (means neither fragments nor raw_arguments provided usable JSON).
        if Enum.any?(tool_calls, fn tc ->
             args = if is_struct(tc), do: tc.arguments, else: Map.get(tc, :arguments)
             args == %{} or is_nil(args)
           end) do
          Logger.warning(
            "#{@log_prefix} [diag] tool_call with empty args after patching — " <>
              "buffer=#{inspect(final.tool_call_args_buffer)} " <>
              "text_snippet=#{preview(text, 200)} " <>
              "calls=#{inspect(Enum.map(tool_calls, fn tc -> {Map.get(tc, :name) || (is_struct(tc) && tc.name), Map.get(tc, :arguments) || (is_struct(tc) && tc.arguments)} end))}"
          )
        else
          Logger.debug(fn ->
            calls_preview =
              Enum.map_join(tool_calls, ", ", fn tc ->
                name = if is_struct(tc), do: tc.name, else: Map.get(tc, :name)
                args = if is_struct(tc), do: tc.arguments, else: Map.get(tc, :arguments)
                "#{name}(#{inspect(args, limit: 5, printable_limit: 200)})"
              end)

            "#{@log_prefix} ←tool_calls_resolved #{calls_preview}"
          end)
        end

        {:ok,
         %Response{
           text: text,
           thinking: if(thinking == "", do: nil, else: thinking),
           tool_calls: tool_calls,
           finish_reason: final.finish_reason || :stop,
           model: final.model,
           provider: :req_llm,
           usage: final.usage
         }}
    end
  end

  # Merge accumulated argument fragments back into each tool call.
  # Handles two llama.cpp streaming quirks:
  # 1. Args split across the initial chunk (raw_arguments in metadata) and later
  #    fragment deltas (accumulated in the buffer) — combine before decoding.
  # 2. Args streamed without the opening `{` — reconstruct by prepending it.
  defp patch_tool_call_args(tool_calls, buffer) when map_size(buffer) == 0 do
    Enum.map(tool_calls, &patch_from_raw_arguments/1)
  end

  defp patch_tool_call_args(tool_calls, buffer) do
    Enum.map(tool_calls, fn tc ->
      index = tc.metadata && (Map.get(tc.metadata, :index) || Map.get(tc.metadata, "index"))

      case index && Map.get(buffer, index) do
        nil ->
          patch_from_raw_arguments(tc)

        accumulated ->
          # Prepend any partial prefix sent in the initial chunk before the fragments.
          raw_prefix = (tc.metadata && Map.get(tc.metadata, :raw_arguments)) || ""
          try_decode_accumulated(raw_prefix <> accumulated, tc)
      end
    end)
  end

  # When there's no buffer entry, try the raw_arguments from the initial chunk
  # (covers cases where llama.cpp sends complete-but-malformed JSON in one shot).
  defp patch_from_raw_arguments(tc) do
    case tc.metadata && Map.get(tc.metadata, :raw_arguments) do
      raw when is_binary(raw) and raw != "" -> try_decode_accumulated(raw, tc)
      _ -> tc
    end
  end

  defp try_decode_accumulated(accumulated, tc) do
    case Jason.decode(accumulated) do
      {:ok, decoded} when is_map(decoded) ->
        %{tc | arguments: decoded}

      _ ->
        case try_wrap_accumulated(accumulated) do
          {:ok, decoded} -> %{tc | arguments: decoded}
          :error -> tc
        end
    end
  end

  defp try_wrap_accumulated(accumulated) do
    cond do
      String.starts_with?(accumulated, "{") ->
        Jason.decode(accumulated)

      String.starts_with?(accumulated, "\"") ->
        # llama.cpp streams the JSON body without the opening `{` — just prepend it.
        # Works for any value type (string, number, bool), not just string-terminated.
        case Jason.decode("{" <> accumulated) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> :error
        end

      true ->
        :error
    end
  end

  # ── Heartbeat / TTFT (visibility while Ollama is processing) ──────────
  #
  # Local Ollama on a 14B+ model can spend 30–120s processing the prompt
  # before emitting the first chunk. Without any signal on the wire,
  # callers can't tell a slow-but-alive request from a stalled one. Emit a
  # `⋯ waiting on stream (Ns elapsed)` heartbeat every 10s until the first
  # content/tool_call chunk arrives, then log the TTFT exactly once.

  @heartbeat_interval_ms 10_000

  defp start_heartbeat(start_ms) do
    parent = self()

    spawn(fn ->
      heartbeat_loop(parent, start_ms)
    end)
  end

  defp heartbeat_loop(parent, start_ms) do
    receive do
      :stop -> :ok
    after
      @heartbeat_interval_ms ->
        if Process.alive?(parent) do
          elapsed_s = div(System.monotonic_time(:millisecond) - start_ms, 1000)
          Logger.info("#{@log_prefix} ⋯ waiting on stream (#{elapsed_s}s elapsed)")
          heartbeat_loop(parent, start_ms)
        else
          :ok
        end
    end
  end

  defp stop_heartbeat(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp maybe_log_first_chunk(%{type: type}, %{first_chunk_logged: false} = acc)
       when type in [:content, :tool_call] do
    elapsed_ms = System.monotonic_time(:millisecond) - acc.stream_started_ms
    Logger.info("#{@log_prefix} ←first_chunk after #{elapsed_ms}ms (TTFT)")
    %{acc | first_chunk_logged: true}
  end

  defp maybe_log_first_chunk(_chunk, acc), do: acc

  defp handle_chunk(%{type: :content, text: text}, callback, acc) when is_binary(text) do
    Logger.debug(fn ->
      "#{@log_prefix} ←text_delta #{byte_size(text)}B: #{preview(text, 80)}"
    end)

    ExAthena.Streaming.text_delta(callback, text)
    %{acc | text: [text | acc.text], streamed_bytes: acc.streamed_bytes + byte_size(text)}
  end

  defp handle_chunk(%{type: :thinking, text: text}, callback, acc) when is_binary(text) do
    Logger.debug(fn ->
      "#{@log_prefix} ←thinking_delta #{byte_size(text)}B: #{preview(text, 80)}"
    end)

    ExAthena.Streaming.thinking_delta(callback, text)
    %{acc | thinking: [text | acc.thinking], streamed_bytes: acc.streamed_bytes + byte_size(text)}
  end

  defp handle_chunk(%{type: :tool_call} = tc, _callback, acc) do
    Logger.debug(fn ->
      name = Map.get(tc, :name) || Map.get(tc, "name") || "<unknown>"
      args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{}
      index = tc.metadata && (Map.get(tc.metadata, :index) || Map.get(tc.metadata, "index"))
      suffix = if args == %{}, do: " (args pending fragments; index=#{inspect(index)})", else: ""

      "#{@log_prefix} ←tool_call name=#{inspect(name)} args=#{inspect(args, limit: 3, printable_limit: 200)}#{suffix}"
    end)

    %{acc | tool_calls: acc.tool_calls ++ [tc]}
  end

  # Accumulate tool-call argument fragments emitted by OpenAI-style streaming
  # (each delta carries a JSON substring; we reassemble them in the buffer).
  defp handle_chunk(
         %{type: :meta, metadata: %{tool_call_args: %{index: index, fragment: frag}}},
         _callback,
         acc
       ) do
    updated = Map.update(acc.tool_call_args_buffer, index, frag, &(&1 <> frag))

    # Logger.debug(fn ->
    #   total = byte_size(Map.get(updated, index, ""))
    #   "#{@log_prefix} ←tool_call_args_frag index=#{index} +#{byte_size(frag)}B (buf total #{total}B)"
    # end)

    %{acc | tool_call_args_buffer: updated}
  end

  # `StreamChunk` carries usage and finish_reason inside `metadata`, not as
  # top-level fields. The old patterns (`%{type: :usage, usage: …}` and
  # `%{type: :meta, finish_reason: …}`) never matched the actual struct shape.
  defp handle_chunk(%{type: :meta, metadata: metadata}, _callback, acc)
       when is_map(metadata) do
    acc
    |> then(fn a ->
      case Map.get(metadata, :finish_reason) do
        nil ->
          a

        reason ->
          Logger.debug(fn -> "#{@log_prefix} ←meta finish_reason=#{inspect(reason)}" end)
          %{a | finish_reason: reason}
      end
    end)
    |> then(fn a ->
      case Map.get(metadata, :usage) do
        nil ->
          a

        usage ->
          Logger.debug(fn -> "#{@log_prefix} ←usage #{inspect(usage)}" end)
          %{a | usage: usage}
      end
    end)
  end

  defp handle_chunk(_chunk, _callback, acc), do: acc

  # ── Logging helpers (Claude Code-style adapter-boundary breadcrumbs) ──

  defp log_request(kind, model_spec, %Request{} = request, messages, req_opts) do
    base_url = Keyword.get(req_opts, :base_url) || "<provider default>"
    backend = Keyword.get(req_opts, :openai_compatible_backend)
    n_msgs = length(messages)
    n_tools = length(Keyword.get(req_opts, :tools, []) || [])

    Logger.info(
      "#{@log_prefix} →#{kind} model=#{inspect(model_spec)} msgs=#{n_msgs} tools=#{n_tools} " <>
        "base_url=#{base_url}#{if backend, do: " backend=#{inspect(backend)}", else: ""}"
    )

    Logger.debug(fn ->
      sp_preview =
        case request.system_prompt do
          nil -> "nil"
          "" -> "\"\""
          str when is_binary(str) -> "#{byte_size(str)}B: #{preview(str, 200)}"
        end

      msg_lines =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {%ReqLLM.Message{role: role, content: parts}, i} ->
          text = parts |> Enum.map(&content_part_text/1) |> Enum.join(" ")
          "  msg[#{i}] #{role}: #{preview(text, 200)}"
        end)
        |> Enum.join("\n")

      "#{@log_prefix} →#{kind} system_prompt=#{sp_preview}\n#{msg_lines}"
    end)
  end

  defp log_response(%Response{} = resp) do
    text_chars = byte_size(resp.text || "")
    n_tool_calls = length(resp.tool_calls || [])

    Logger.info(
      "#{@log_prefix} ←done finish_reason=#{inspect(resp.finish_reason)} " <>
        "text_chars=#{text_chars} tool_calls=#{n_tool_calls} " <>
        "usage=#{inspect(resp.usage, limit: 5)}"
    )

    Logger.debug(fn ->
      "#{@log_prefix} ←done text_preview=#{preview(resp.text || "", 300)}"
    end)
  end

  defp log_error(reason) do
    Logger.warning("#{@log_prefix} ←error #{inspect(reason, limit: 5, printable_limit: 500)}")
  end

  defp content_part_text(%ReqLLM.Message.ContentPart{text: text}) when is_binary(text), do: text
  defp content_part_text(_), do: ""

  defp preview(str, max) when is_binary(str) do
    cleaned = String.replace(str, ~r/\s+/, " ")

    if byte_size(cleaned) <= max do
      inspect(cleaned)
    else
      inspect(binary_part(cleaned, 0, max) <> "…")
    end
  end

  # ── Error mapping ─────────────────────────────────────────────────

  defp to_error(%{status: status} = raw) when is_integer(status) do
    kind =
      if context_overflow?(raw), do: :context_length_exceeded, else: Error.from_status(status)

    Error.new(kind, "req_llm error",
      provider: :req_llm,
      status: status,
      raw: raw
    )
  end

  defp to_error(reason) do
    kind = if context_overflow?(reason), do: :context_length_exceeded, else: :server_error
    Error.new(kind, inspect(reason), provider: :req_llm, raw: reason)
  end

  # OpenAI-compatible local servers (exo/llama.cpp/vLLM/ollama) signal
  # context overflow with 400/500 + a message body, never a clean 413 —
  # without sniffing, the loop's compact-and-retry path is dead code and
  # runs die :error_during_execution instead of compacting.
  @doc false
  def context_overflow?(raw) do
    raw
    |> inspect(limit: 2_000)
    |> String.downcase()
    |> then(fn text ->
      String.contains?(text, "context length") or
        String.contains?(text, "context_length") or
        String.contains?(text, "maximum context") or
        String.contains?(text, "too many tokens") or
        String.contains?(text, "exceeds the context") or
        String.contains?(text, "prompt is too long") or
        String.contains?(text, "context window")
    end)
  end

  # ── llm_db context resolution ─────────────────────────────────────

  defp resolve_llmdb_context(opts) do
    with tag when is_binary(tag) and tag != "" <- Keyword.get(opts, :req_llm_provider_tag),
         {:ok, provider_atom} <- safe_to_atom(tag),
         model_str when is_binary(model_str) and model_str != "" <-
           Keyword.get(opts, :model, ""),
         model_id = strip_provider_prefix(model_str, tag),
         {:ok, %LLMDB.Model{limits: limits}} <- LLMDB.model(provider_atom, model_id),
         context when is_integer(context) and context > 0 <- (limits || %{})[:context] do
      {:ok, context}
    else
      _ -> :error
    end
  end

  defp safe_to_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end

  defp strip_provider_prefix(model, tag) do
    prefix = tag <> ":"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end
end
