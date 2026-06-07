defmodule ExAthena.Messages do
  @moduledoc """
  Canonical in-memory representation of a conversation.

  Every provider normalises its wire format into this shape so the agent loop,
  tool-call parsers, and consumer code all speak the same dialect.
  """

  defmodule ToolCall do
    @moduledoc "A tool call the model wants the runtime to execute."

    @enforce_keys [:id, :name, :arguments]
    defstruct [:id, :name, :arguments]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            arguments: map()
          }
  end

  defmodule ToolResult do
    @moduledoc """
    The outcome of a tool execution, replayed back to the model.

    `content` is the LLM-facing text — what the model sees on the next
    iteration. `ui_payload` is an optional structured map that hosts
    (TUIs, LiveView frontends) can render as rich content (diffs, file
    previews, process output) without parsing the text.

    `ui_payload` is `nil` for tools that only return text; the loop
    only emits `:tool_ui` events when a payload is present.
    """

    @enforce_keys [:tool_call_id, :content]
    defstruct [:tool_call_id, :content, :is_error, :ui_payload]

    @type ui_payload :: %{
            required(:kind) => atom(),
            required(:payload) => map()
          }

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            content: String.t(),
            is_error: boolean() | nil,
            ui_payload: ui_payload() | nil
          }
  end

  defmodule Message do
    @moduledoc "A single turn in the conversation."

    @enforce_keys [:role]
    defstruct [:role, :content, :tool_calls, :tool_results, :name, :reasoning, pin: false]

    @type role :: :system | :user | :assistant | :tool
    @type t :: %__MODULE__{
            role: role(),
            content: String.t() | [ExAthena.Messages.ContentPart.t()] | nil,
            tool_calls: [ToolCall.t()] | nil,
            tool_results: [ToolResult.t()] | nil,
            name: String.t() | nil,
            # Raw chain-of-thought for this assistant turn (verbatim; kept
            # out of content). Replayed within the CURRENT tool loop only
            # (rolling checkpoint) — see Providers.ReqLLM.
            reasoning: String.t() | nil,
            pin: boolean()
          }
  end

  @doc "Build a user message."
  @spec user(String.t() | [ExAthena.Messages.ContentPart.t()]) :: Message.t()
  def user(content) when is_binary(content),
    do: %Message{role: :user, content: content}

  def user(parts) when is_list(parts),
    do: %Message{role: :user, content: parts}

  @doc "Build an assistant message (optionally with tool calls and reasoning)."
  @spec assistant(String.t() | nil, [ToolCall.t()] | nil, String.t() | nil) :: Message.t()
  def assistant(content, tool_calls \\ nil, reasoning \\ nil) do
    %Message{role: :assistant, content: content, tool_calls: tool_calls, reasoning: reasoning}
  end

  @doc "Build a system message."
  @spec system(String.t()) :: Message.t()
  def system(content) when is_binary(content),
    do: %Message{role: :system, content: content}

  @doc "Build a tool-result message replaying the output of a tool call."
  @spec tool_result(String.t(), String.t(), boolean() | nil, ToolResult.ui_payload() | nil) ::
          Message.t()
  def tool_result(tool_call_id, content, is_error \\ nil, ui_payload \\ nil) do
    %Message{
      role: :tool,
      tool_results: [
        %ToolResult{
          tool_call_id: tool_call_id,
          content: content,
          is_error: is_error,
          ui_payload: ui_payload
        }
      ]
    }
  end

  @doc """
  Turn a loose map/keyword into a `Message`. Tolerant of both string and atom
  keys so provider JSON and user-constructed data both work.
  """
  @spec from_map(map() | Message.t()) :: Message.t()
  def from_map(%Message{} = m), do: m

  def from_map(map) when is_map(map) do
    %Message{
      role: fetch_role(map),
      content: maybe_content_parts(fetch(map, :content)),
      tool_calls: maybe_tool_calls(fetch(map, :tool_calls)),
      tool_results: maybe_tool_results(fetch(map, :tool_results)),
      name: fetch(map, :name),
      pin: fetch(map, :pin) || false
    }
  end

  defp fetch_role(map) do
    case fetch(map, :role) do
      nil -> raise ArgumentError, "message must have a :role"
      role when is_atom(role) -> role
      role when is_binary(role) -> String.to_existing_atom(role)
      _ -> raise ArgumentError, "message must have a :role"
    end
  end

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_content_parts(nil), do: nil
  defp maybe_content_parts(str) when is_binary(str), do: str

  defp maybe_content_parts(parts) when is_list(parts),
    do: Enum.map(parts, &to_content_part/1)

  defp to_content_part(%ExAthena.Messages.ContentPart{} = cp), do: cp

  defp to_content_part(map) when is_map(map) do
    type = fetch_atom(map, :type)

    %ExAthena.Messages.ContentPart{
      type: type,
      text: fetch(map, :text),
      url: fetch(map, :url),
      data: fetch(map, :data),
      media_type: fetch(map, :media_type),
      filename: fetch(map, :filename)
    }
  end

  defp fetch_atom(map, key) do
    case fetch(map, key) do
      nil -> nil
      v when is_atom(v) -> v
      v when is_binary(v) -> String.to_existing_atom(v)
    end
  end

  defp maybe_tool_calls(nil), do: nil
  defp maybe_tool_calls([]), do: []

  defp maybe_tool_calls(calls) when is_list(calls),
    do: Enum.map(calls, &to_tool_call/1)

  defp maybe_tool_results(nil), do: nil
  defp maybe_tool_results([]), do: []

  defp maybe_tool_results(results) when is_list(results),
    do: Enum.map(results, &to_tool_result/1)

  defp to_tool_call(%ToolCall{} = tc), do: tc

  defp to_tool_call(map) when is_map(map) do
    %ToolCall{
      id: fetch(map, :id),
      name: fetch(map, :name),
      arguments: fetch(map, :arguments) || %{}
    }
  end

  defp to_tool_result(%ToolResult{} = tr), do: tr

  defp to_tool_result(map) when is_map(map) do
    %ToolResult{
      tool_call_id: fetch(map, :tool_call_id),
      content: fetch(map, :content),
      is_error: fetch(map, :is_error)
    }
  end
end
