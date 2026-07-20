defmodule ExAthena.ToolCalls do
  @moduledoc """
  Extracts tool calls from a provider response.

  Three parsers:

    * `ExAthena.ToolCalls.Native` — structured `tool_calls` array from the
      provider (OpenAI-style `function` + `arguments`, Claude `tool_use`
      blocks, Ollama's OpenAI-compatible payload).
    * `ExAthena.ToolCalls.TextTagged` — prompt-engineered
      `~~~tool_call <json> ~~~` blocks embedded in the assistant's text.
    * `ExAthena.ToolCalls.RawJson` — bare or `` ```json ``-fenced JSON objects
      emitted by weak open-weight models that ignore both native tool-call
      APIs and the `~~~tool_call` fence format.

  ## Auto-fallback

  `extract/2` cascades through three tiers based on the response content and
  `provider_capabilities.native_tool_calls`:

    1. Structured `tool_calls` present → `Native.parse/1`.
    2. Text contains `~~~tool_call` fences, or provider declared no native
       support → `TextTagged.parse/1`.
    3. Text looks like a raw JSON tool call (has both `"name"` and
       `"arguments"` substrings) → `RawJson.parse/1`.
    4. No match → `{:ok, []}`.

  The agent loop uses `augment_system_prompt/2` to add text-tagged instructions
  when a provider lacks native support.
  """

  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolCalls.{Native, RawJson, TextTagged}

  @type provider_response :: %{
          optional(:text) => String.t() | nil,
          optional(:tool_calls) => list() | nil
        }

  @doc """
  Extract tool calls from a provider response.

  Returns `{:ok, [ToolCall.t()]}` — always a list (possibly empty), never
  `nil`. Pass capabilities so the parser can pick the right protocol.
  """
  @spec extract(provider_response(), ExAthena.Capabilities.t()) ::
          {:ok, [ToolCall.t()]} | {:error, term()}
  def extract(response, capabilities \\ %{})

  # Self-contained agents (e.g. the Claude Code CLI) run their own tools and
  # own the loop. Their text may mention or even echo `~~~tool_*` fences, but
  # the loop must never parse or execute them — the turn is terminal.
  def extract(_response, %{self_contained_tools: true}), do: {:ok, []}

  def extract(%{tool_calls: [_ | _] = calls}, _caps) when is_list(calls) do
    Native.parse(calls)
  end

  def extract(%{text: text}, %{native_tool_calls: false}) when is_binary(text) do
    with {:ok, []} <- TextTagged.parse(text) do
      cond do
        String.contains?(text, "<tool_call>") -> parse_xml_tool_calls(text)
        bare_json_message?(text) -> RawJson.parse(text)
        true -> {:ok, []}
      end
    end
  end

  def extract(%{text: text}, _caps) when is_binary(text) do
    # Native was claimed (or unknown) but came back empty — cascade through
    # the leak-rescue tiers. exo/MLX servers are known to leak Qwen-style
    # <tool_call> XML into content with tool_calls: null; small non-native
    # models emit bare JSON. The bare-JSON tier requires the message to BE
    # the JSON — prose merely QUOTING a call (terminal answers, examples)
    # must never execute.
    cond do
      String.contains?(text, "~~~tool_call") -> TextTagged.parse(text)
      String.contains?(text, "<tool_call>") -> parse_xml_tool_calls(text)
      bare_json_message?(text) -> RawJson.parse(text)
      true -> {:ok, []}
    end
  end

  def extract(_response, _caps), do: {:ok, []}

  # Qwen3+-style leaked tool calls: <tool_call>{"name":…,"arguments":…}</tool_call>
  defp parse_xml_tool_calls(text) do
    calls =
      ~r/<tool_call>\s*(\{.*?\})\s*<\/tool_call>/s
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.flat_map(fn [json] ->
        case Jason.decode(json) do
          {:ok, %{"name" => _} = map} -> [map]
          _ -> []
        end
      end)

    case calls do
      [] -> {:ok, []}
      list -> Native.parse(list)
    end
  end

  # The message IS a tool call (after stripping any think block): it must
  # start with the JSON itself, not mention one mid-prose.
  defp bare_json_message?(text) do
    stripped =
      text
      |> String.replace(~r/<think>.*?<\/think>/s, "")
      |> String.trim()

    String.starts_with?(stripped, ["{", "["]) and
      String.contains?(stripped, ~s("name")) and String.contains?(stripped, ~s("arguments"))
  end

  @doc """
  Append text-tagged tool-call instructions to a system prompt so
  non-native-tool-call providers know how to respond.

  `ExAthena.Loop` calls this when the chosen provider lacks native tool-call
  support, or when the user has forced TextTagged mode.

  ## Options

    * `:compact` — when `true`, emits a one-line-per-tool signature instead
      of the full JSON schema. Useful for weak open-weight models that degrade
      past ~4 KB system prompts. Default: `false`.
  """
  @spec augment_system_prompt(String.t() | nil, [map()], keyword()) :: String.t()
  def augment_system_prompt(existing, tools, opts \\ []) when is_list(tools) do
    existing = existing || ""

    formatter =
      if Keyword.get(opts, :compact, false),
        do: &format_tool_list_compact/1,
        else: &format_tool_list/1

    preamble = """
    You have access to the following tools. When you want to call a tool,
    respond with a fenced block using this exact shape — no other format is
    accepted:

        ~~~tool_call
        {"name": "<tool>", "arguments": {"arg1": "...", "arg2": "..."}}
        ~~~

    Emit one `~~~tool_call` block per call. Multiple blocks in a single
    response are allowed. When you are done using tools, respond with plain
    text only (no fences) and the runtime will stop.

    Available tools:

    #{formatter.(tools)}
    """

    if String.trim(existing) == "" do
      preamble
    else
      existing <> "\n\n" <> preamble
    end
  end

  defp format_tool_list(tools) do
    tools
    |> Enum.map_join("\n\n", fn tool ->
      name = Map.get(tool, :name) || Map.get(tool, "name")
      desc = Map.get(tool, :description) || Map.get(tool, "description") || ""
      schema = Map.get(tool, :schema) || Map.get(tool, "schema") || %{}

      """
      - `#{name}` — #{desc}
        Schema: #{Jason.encode!(schema)}
      """
    end)
  end

  defp format_tool_list_compact(tools) do
    Enum.map_join(tools, "\n", &compact_tool_line/1)
  end

  defp compact_tool_line(tool) do
    name = Map.get(tool, :name) || Map.get(tool, "name") || "<unnamed>"
    desc = Map.get(tool, :description) || Map.get(tool, "description") || ""
    schema = Map.get(tool, :schema) || Map.get(tool, "schema") || %{}

    sig = "#{name}(#{compact_params(schema)})"
    short = short_desc(desc)

    if short == "", do: "- #{sig}", else: "- #{sig} — #{short}"
  end

  defp compact_params(schema) do
    properties = Map.get(schema, :properties) || Map.get(schema, "properties")

    required =
      (Map.get(schema, :required) || Map.get(schema, "required") || []) |> Enum.map(&to_string/1)

    case properties do
      nil ->
        ""

      props when map_size(props) == 0 ->
        ""

      props ->
        props
        |> Enum.sort_by(fn {k, _} -> {to_string(k) not in required, to_string(k)} end)
        |> Enum.map(fn {k, v} ->
          key = to_string(k)
          type_str = compact_type(v)
          if key in required, do: "#{key}: #{type_str}", else: "#{key}?: #{type_str}"
        end)
        |> Enum.join(", ")
    end
  end

  defp compact_type(schema) when is_map(schema) do
    type = Map.get(schema, :type) || Map.get(schema, "type")
    items = Map.get(schema, :items) || Map.get(schema, "items")

    cond do
      type == "array" and is_map(items) ->
        item_type = Map.get(items, :type) || Map.get(items, "type")

        if item_type in ~w(string number integer boolean null),
          do: "#{item_type}[]",
          else: "array"

      type in ~w(string number integer boolean null object) ->
        type

      true ->
        "object"
    end
  end

  defp compact_type(_), do: "object"

  defp short_desc(desc) when is_binary(desc) do
    cleaned = desc |> String.replace(~r/\s+/, " ") |> String.trim()

    case cleaned do
      "" ->
        ""

      s ->
        sentence =
          case String.split(s, ". ", parts: 2) do
            [first, _rest] -> first <> "."
            [only] -> only
          end

        if String.length(sentence) > 80, do: String.slice(sentence, 0, 80), else: sentence
    end
  end

  defp short_desc(_), do: ""
end
