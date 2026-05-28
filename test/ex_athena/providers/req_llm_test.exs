defmodule ExAthena.Providers.ReqLLMTest do
  use ExUnit.Case, async: true

  alias ExAthena.Config
  alias ExAthena.Providers.ReqLLM, as: Adapter

  describe "capabilities/0 conservative fallback" do
    test "declares streaming + native tool-calls + json mode" do
      caps = Adapter.capabilities()
      assert caps.streaming
      assert caps.native_tool_calls
      assert caps.json_mode
    end

    test "declares structured_output: true" do
      assert Adapter.capabilities().structured_output == true
    end

    test "returns max_tokens: 8_192 as conservative fallback" do
      assert Adapter.capabilities().max_tokens == 8_192
    end
  end

  describe "capabilities/1 llm_db resolution" do
    setup do
      LLMDB.load()
      :ok
    end

    test "with empty opts returns conservative fallback" do
      assert Adapter.capabilities([]).max_tokens == 8_192
    end

    test "with provider tag but no model returns conservative fallback" do
      opts = [req_llm_provider_tag: "openai"]
      assert Adapter.capabilities(opts).max_tokens == 8_192
    end

    test "with a model not in llm_db returns conservative fallback" do
      opts = [model: "custom-local:7b", req_llm_provider_tag: "openai"]
      assert Adapter.capabilities(opts).max_tokens == 8_192
    end

    test "uses llm_db context for known openai model" do
      opts = [model: "gpt-4o-mini", req_llm_provider_tag: "openai"]
      caps = Adapter.capabilities(opts)
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      assert caps.max_tokens == model.limits[:context]
    end

    test "uses llm_db context for known anthropic model" do
      opts = [model: "claude-opus-4-5", req_llm_provider_tag: "anthropic"]
      caps = Adapter.capabilities(opts)
      {:ok, model} = LLMDB.model(:anthropic, "claude-opus-4-5")
      assert caps.max_tokens == model.limits[:context]
      assert caps.max_tokens >= 100_000
    end

    test "preserves all other capability flags from capabilities/0" do
      opts = [model: "gpt-4o-mini", req_llm_provider_tag: "openai"]
      caps = Adapter.capabilities(opts)
      assert caps.streaming == true
      assert caps.native_tool_calls == true
      assert caps.json_mode == true
      assert caps.structured_output == true
      assert caps.compact_tool_schemas == true
    end
  end

  describe "Config resolves builtin provider atoms to the ReqLLM adapter" do
    test ":ollama, :openai*, :llamacpp, :claude, :anthropic, :openrouter all route here" do
      for atom <- [
            :ollama,
            :openai,
            :openai_compatible,
            :llamacpp,
            :claude,
            :anthropic,
            :openrouter,
            :req_llm
          ] do
        assert Config.provider_module(atom) == Adapter,
               "expected provider atom #{inspect(atom)} to resolve to ReqLLM adapter"
      end
    end

    test ":mock stays on the Mock provider" do
      assert Config.provider_module(:mock) == ExAthena.Providers.Mock
    end
  end

  describe "Config threads the req_llm provider tag into opts" do
    test ":ollama uses the openai tag (Ollama is OpenAI-compatible)" do
      {_mod, opts} = Config.pop_provider!(provider: :ollama)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":ollama threads openai_compatible_backend so missing API keys are tolerated" do
      {_mod, opts} = Config.pop_provider!(provider: :ollama)
      assert Keyword.get(opts, :openai_compatible_backend) == :ollama
    end

    test ":llamacpp uses the openai tag (llama.cpp is OpenAI-compatible)" do
      {_mod, opts} = Config.pop_provider!(provider: :llamacpp)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":llamacpp threads openai_compatible_backend so missing API keys are tolerated" do
      {_mod, opts} = Config.pop_provider!(provider: :llamacpp)
      assert Keyword.get(opts, :openai_compatible_backend) == :llamacpp
    end

    test ":claude translates to anthropic tag" do
      {_mod, opts} = Config.pop_provider!(provider: :claude)
      assert Keyword.get(opts, :req_llm_provider_tag) == "anthropic"
    end

    test ":openai_compatible uses openai tag" do
      {_mod, opts} = Config.pop_provider!(provider: :openai_compatible)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":openai_compatible does NOT inject the ollama backend marker" do
      {_mod, opts} = Config.pop_provider!(provider: :openai_compatible)
      refute Keyword.has_key?(opts, :openai_compatible_backend)
    end

    test ":openrouter uses the openai tag (OpenRouter is OpenAI wire-compatible)" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":openrouter does NOT inject the openai_compatible_backend marker" do
      {_mod, opts} = Config.pop_provider!(provider: :openrouter)
      refute Keyword.has_key?(opts, :openai_compatible_backend)
    end

    test ":mock has no tag" do
      {_mod, opts} = Config.pop_provider!(provider: :mock)
      refute Keyword.has_key?(opts, :req_llm_provider_tag)
    end
  end

  describe "resolve_model/2 prefixes the provider tag correctly" do
    alias ExAthena.Request

    test "materializes a tagged inline %LLMDB.Model{} for bare model ids" do
      # Materializing via `ReqLLM.model!/1` (rather than returning a tagged
      # string) skips req_llm's catalog lookup, which avoids the
      # `Using unverified model: openai:<id>` IO.warn for non-catalog ids
      # like Ollama's `gemma:7b`.
      assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4"}} =
               Adapter.resolve_model(%Request{messages: [], model: "gpt-4"},
                 req_llm_provider_tag: "openai"
               )
    end

    test "preserves Ollama-style version-tag colons in the inline spec" do
      # Regression: Ollama model ids use `:` as the version separator
      # (`qwen2.5-coder:14b`). The id must reach req_llm verbatim, including
      # the colon — otherwise the openai adapter sees a truncated model id.
      assert {:ok, %LLMDB.Model{provider: :openai, id: "qwen2.5-coder:14b"}} =
               Adapter.resolve_model(
                 %Request{messages: [], model: "qwen2.5-coder:14b"},
                 req_llm_provider_tag: "openai"
               )

      assert {:ok, %LLMDB.Model{provider: :openai, id: "qwen3-coder:30b"}} =
               Adapter.resolve_model(
                 %Request{messages: [], model: "qwen3-coder:30b"},
                 req_llm_provider_tag: "openai"
               )
    end

    test "strips a leading tag prefix when the caller passed a fully-formed spec" do
      assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4"}} =
               Adapter.resolve_model(
                 %Request{messages: [], model: "openai:gpt-4"},
                 req_llm_provider_tag: "openai"
               )

      assert {:ok, %LLMDB.Model{provider: :openai, id: "qwen2.5-coder:14b"}} =
               Adapter.resolve_model(
                 %Request{messages: [], model: "openai:qwen2.5-coder:14b"},
                 req_llm_provider_tag: "openai"
               )
    end

    test "passes the model through unchanged when no tag is set" do
      assert Adapter.resolve_model(%Request{messages: [], model: "qwen2.5-coder:14b"}, []) ==
               {:ok, "qwen2.5-coder:14b"}
    end

    test "falls back to opts[:model] when the request has no model and prefixes the tag" do
      assert {:ok, %LLMDB.Model{provider: :openai, id: "qwen2.5-coder:14b"}} =
               Adapter.resolve_model(
                 %Request{messages: [], model: nil},
                 model: "qwen2.5-coder:14b",
                 req_llm_provider_tag: "openai"
               )
    end

    test "errors when no model is supplied anywhere" do
      assert {:error, %ExAthena.Error{kind: :bad_request, message: "no model configured"}} =
               Adapter.resolve_model(%Request{messages: [], model: nil}, [])
    end
  end

  describe "to_req_llm_tools/1" do
    test "returns nil and [] unchanged" do
      assert Adapter.to_req_llm_tools(nil) == nil
      assert Adapter.to_req_llm_tools([]) == []
    end

    test "passes through %ReqLLM.Tool{} structs unchanged (forward compat)" do
      tool = %ReqLLM.Tool{
        name: "passthrough",
        description: "already a struct",
        parameter_schema: %{},
        callback: fn _ -> {:ok, ""} end
      }

      assert [^tool] = Adapter.to_req_llm_tools([tool])
    end

    test "converts atom-keyed OpenAI-format maps (the modes/react.ex shape) to ReqLLM.Tool" do
      # Regression: req_llm 1.10's openai adapter calls
      # ReqLLM.Tool.to_schema(tool, :openai) on each entry, which only
      # matches %ReqLLM.Tool{}. Previously these maps reached req_llm raw
      # and crashed with "no function clause matching".
      tool_map = %{
        type: "function",
        function: %{
          name: "read",
          description: "Read a file",
          parameters: %{
            type: "object",
            properties: %{path: %{type: "string"}},
            required: ["path"]
          }
        }
      }

      assert [%ReqLLM.Tool{} = tool] = Adapter.to_req_llm_tools([tool_map])
      assert tool.name == "read"
      assert tool.description == "Read a file"
      assert tool.parameter_schema == tool_map.function.parameters
      assert is_function(tool.callback, 1)
    end

    test "also accepts string-keyed OpenAI-format maps" do
      tool_map = %{
        "type" => "function",
        "function" => %{
          "name" => "grep",
          "description" => "Search files",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }

      assert [%ReqLLM.Tool{} = tool] = Adapter.to_req_llm_tools([tool_map])
      assert tool.name == "grep"
      assert tool.description == "Search files"
    end

    test "the stub callback returns a tagged error so accidental use is loud" do
      tool_map = %{
        type: "function",
        function: %{name: "x", description: "y", parameters: %{}}
      }

      [%ReqLLM.Tool{callback: cb}] = Adapter.to_req_llm_tools([tool_map])
      assert cb.(%{}) == {:error, :tool_execution_handled_by_ex_athena}
    end
  end

  describe "build_opts/2 substitutes a placeholder api_key for backends that ignore auth" do
    alias ExAthena.Request

    test ":ollama backend with no api_key gets the \"ollama\" placeholder" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, openai_compatible_backend: :ollama)
      assert Keyword.get(opts, :api_key) == "ollama"
    end

    test ":llamacpp backend with no api_key gets the \"llamacpp\" placeholder" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, openai_compatible_backend: :llamacpp)
      assert Keyword.get(opts, :api_key) == "llamacpp"
    end

    test "explicit api_key wins over the placeholder for :llamacpp" do
      request = %Request{messages: []}

      {:ok, opts} =
        Adapter.build_opts(request, openai_compatible_backend: :llamacpp, api_key: "real-key")

      assert Keyword.get(opts, :api_key) == "real-key"
    end

    test "no backend marker means no placeholder substitution" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, [])
      refute Keyword.has_key?(opts, :api_key)
    end
  end

  describe "to_req_llm_message/1 assistant tool_calls replay shape" do
    alias ExAthena.Messages.{Message, ToolCall}

    test "map arguments are JSON-encoded into ReqLLM.ToolCall with type: function" do
      msg = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [%ToolCall{id: "call_1", name: "read_file", arguments: %{"path" => "x"}}]
      }

      %ReqLLM.Message{tool_calls: [tc]} = Adapter.to_req_llm_message(msg)

      assert %ReqLLM.ToolCall{} = tc
      assert tc.id == "call_1"
      assert tc.type == "function"
      assert tc.function.name == "read_file"
      assert tc.function.arguments == ~s({"path":"x"})
    end

    test "nil arguments produce empty JSON object string" do
      msg = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [%ToolCall{id: "call_2", name: "list_files", arguments: nil}]
      }

      %ReqLLM.Message{tool_calls: [tc]} = Adapter.to_req_llm_message(msg)

      assert tc.function.arguments == "{}"
    end

    test "pre-encoded binary arguments are passed through unchanged" do
      json = ~s({"key":"val"})

      msg = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [%ToolCall{id: "call_3", name: "write_file", arguments: json}]
      }

      %ReqLLM.Message{tool_calls: [tc]} = Adapter.to_req_llm_message(msg)

      assert tc.function.arguments == json
    end

    test "absent tool_calls produces nil in the message" do
      msg = %Message{role: :assistant, content: "hello", tool_calls: nil}
      assert %ReqLLM.Message{tool_calls: nil} = Adapter.to_req_llm_message(msg)
    end

    test "empty tool_calls list produces nil in the message" do
      msg = %Message{role: :assistant, content: "hello", tool_calls: []}
      assert %ReqLLM.Message{tool_calls: nil} = Adapter.to_req_llm_message(msg)
    end
  end

  describe "build_opts/2 folds extra_headers into req_http_options" do
    alias ExAthena.Request

    test "folds extra_headers map into req_http_options headers list" do
      request = %Request{messages: []}
      headers = %{"HTTP-Referer" => "https://myapp.io", "X-Title" => "MyApp"}

      {:ok, opts} = Adapter.build_opts(request, extra_headers: headers)

      http_opts = Keyword.get(opts, :req_http_options, [])
      headers_list = Keyword.get(http_opts, :headers, [])

      assert {"HTTP-Referer", "https://myapp.io"} in headers_list
      assert {"X-Title", "MyApp"} in headers_list
    end

    test "does not add req_http_options when extra_headers is absent" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, [])
      refute Keyword.has_key?(opts, :req_http_options)
    end

    test "does not add req_http_options when extra_headers is an empty map" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, extra_headers: %{})
      refute Keyword.has_key?(opts, :req_http_options)
    end

    test "extra_headers is not forwarded as a top-level opt" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, extra_headers: %{"X-Custom" => "val"})
      refute Keyword.has_key?(opts, :extra_headers)
    end

    test "merges extra_headers with existing req_http_options headers" do
      request = %Request{messages: []}
      existing = [headers: [{"X-Existing", "old"}]]

      {:ok, opts} =
        Adapter.build_opts(request,
          extra_headers: %{"X-New" => "new"},
          provider_opts: [req_http_options: existing]
        )

      http_opts = Keyword.get(opts, :req_http_options, [])
      headers_list = Keyword.get(http_opts, :headers, [])
      assert {"X-New", "new"} in headers_list
    end
  end

  describe "build_opts/2 forwards response_format" do
    alias ExAthena.Request

    test "passes :json atom from request.response_format" do
      request = %Request{messages: [], response_format: :json}
      {:ok, opts} = Adapter.build_opts(request, [])
      assert Keyword.get(opts, :response_format) == :json
    end

    test "passes a schema map from request.response_format" do
      schema = %{type: "json_schema", json_schema: %{name: "r", schema: %{}, strict: true}}
      request = %Request{messages: [], response_format: schema}
      {:ok, opts} = Adapter.build_opts(request, [])
      assert Keyword.get(opts, :response_format) == schema
    end

    test "opts[:response_format] overrides request.response_format" do
      request = %Request{messages: [], response_format: :json}
      schema = %{type: "json_schema", json_schema: %{name: "r", schema: %{}, strict: true}}
      {:ok, opts} = Adapter.build_opts(request, response_format: schema)
      assert Keyword.get(opts, :response_format) == schema
    end

    test "omits response_format key when neither opts nor request sets it" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, [])
      refute Keyword.has_key?(opts, :response_format)
    end
  end

  describe "to_req_llm_message/1 multimodal content" do
    alias ExAthena.Messages
    alias ExAthena.Messages.ContentPart

    test "text ContentPart list converts to ReqLLM text parts" do
      msg = Messages.user([ContentPart.text("hello")])
      result = Adapter.to_req_llm_message(msg)
      assert [%ReqLLM.Message.ContentPart{type: :text, text: "hello"}] = result.content
    end

    test "image ContentPart converts to ReqLLM image part" do
      data = "base64data"
      msg = Messages.user([ContentPart.image(data, "image/png")])
      result = Adapter.to_req_llm_message(msg)

      assert [%ReqLLM.Message.ContentPart{type: :image, data: ^data, media_type: "image/png"}] =
               result.content
    end

    test "image_url ContentPart converts to ReqLLM image_url part" do
      msg = Messages.user([ContentPart.image_url("https://example.com/img.png")])
      result = Adapter.to_req_llm_message(msg)

      assert [%ReqLLM.Message.ContentPart{type: :image_url, url: "https://example.com/img.png"}] =
               result.content
    end

    test "file ContentPart converts to ReqLLM file part" do
      msg = Messages.user([ContentPart.file("filedata", "doc.pdf", "application/pdf")])
      result = Adapter.to_req_llm_message(msg)

      assert [
               %ReqLLM.Message.ContentPart{
                 type: :file,
                 data: "filedata",
                 filename: "doc.pdf",
                 media_type: "application/pdf"
               }
             ] = result.content
    end

    test "mixed ContentParts (text + image_url) convert in order" do
      parts = [
        ContentPart.text("describe this"),
        ContentPart.image_url("https://example.com/img.png")
      ]

      msg = Messages.user(parts)
      result = Adapter.to_req_llm_message(msg)

      assert [
               %ReqLLM.Message.ContentPart{type: :text, text: "describe this"},
               %ReqLLM.Message.ContentPart{type: :image_url, url: "https://example.com/img.png"}
             ] = result.content
    end

    test "existing text-only messages still work" do
      msg = Messages.user("plain text")
      result = Adapter.to_req_llm_message(msg)
      assert [%ReqLLM.Message.ContentPart{type: :text, text: "plain text"}] = result.content
    end
  end
end
