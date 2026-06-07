defmodule ExAthena.ToolCalls.Native do
  @moduledoc """
  Parses native tool-call structures from provider responses.

  Handles the four common shapes:

    1. OpenAI / Ollama — `%{id:, type: "function", function: %{name:, arguments: "json"}}`.
       `arguments` is almost always a JSON-encoded string.

    2. Claude — `%{type: "tool_use", id:, name:, input: map()}`.

    3. Pre-parsed — already-parsed `%{id:, name:, arguments: map()}`. No-op.

    4. ReqLLM streaming — `%ReqLLM.StreamChunk{type: :tool_call, name:, arguments:, metadata:}`.
       An optional id is read from `metadata["id"]` or `metadata[:id]`; if absent, one is generated.

  Tolerant of both atom and string keys, and tolerant of either a JSON string
  or a decoded map for `arguments`.
  """

  alias ExAthena.Messages.ToolCall

  @spec parse(list()) :: {:ok, [ToolCall.t()]} | {:error, term()}
  def parse(calls) when is_list(calls) do
    # One bad call must never kill the batch — small models emit broken
    # JSON constantly; the loop turns sentinels into per-call repair errors.
    parsed =
      Enum.flat_map(calls, fn call ->
        case parse_one(call) do
          {:ok, tc} -> [tc]
          {:error, _reason} -> [sentinel(call)]
        end
      end)

    {:ok, parsed |> dedupe_exact() |> ensure_unique_ids()}
  end

  # Exact duplicates (same name + args) are a known small-model failure —
  # executing both wastes a turn and can double-mutate; keep the first.
  defp dedupe_exact(calls) do
    {deduped, _seen} =
      Enum.reduce(calls, {[], MapSet.new()}, fn tc, {acc, seen} ->
        key = {tc.name, tc.arguments}
        if MapSet.member?(seen, key), do: {acc, seen}, else: {[tc | acc], MapSet.put(seen, key)}
      end)

    Enum.reverse(deduped)
  end

  # Colliding ids with DIFFERENT content corrupt the transcript (two tool
  # results for one id → strict servers 400) — re-id the later ones.
  defp ensure_unique_ids(calls) do
    {fixed, _seen} =
      Enum.reduce(calls, {[], MapSet.new()}, fn tc, {acc, seen} ->
        tc = if MapSet.member?(seen, tc.id), do: %{tc | id: generate_id()}, else: tc
        {[tc | acc], MapSet.put(seen, tc.id)}
      end)

    Enum.reverse(fixed)
  end

  # A call we couldn't parse — keep whatever name we can find so the loop
  # can address the error to it, and carry the raw payload for the model.
  defp sentinel(call) do
    name =
      (is_map(call) &&
         (fetch(call, "name") || fetch(call, :name) ||
            fetch(fetch(call, "function") || fetch(call, :function) || %{}, "name"))) ||
        "unknown"

    raw =
      (is_map(call) &&
         (fetch(fetch(call, "function") || fetch(call, :function) || %{}, "arguments") ||
            fetch(call, "arguments") || fetch(call, :arguments))) || call

    %ToolCall{
      id: generate_id(),
      name: to_string(name),
      arguments: %{"__invalid_json__" => String.slice(inspect(raw), 0, 400)}
    }
  end

  defp parse_one(%ToolCall{} = tc), do: {:ok, tc}

  defp parse_one(%{"type" => "function", "id" => id, "function" => fun}) do
    build(id, fetch(fun, "name"), fetch(fun, "arguments"))
  end

  defp parse_one(%{type: "function", id: id, function: fun}) do
    build(
      id,
      fetch(fun, :name) || fetch(fun, "name"),
      fetch(fun, :arguments) || fetch(fun, "arguments")
    )
  end

  defp parse_one(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    build(id, name, input)
  end

  defp parse_one(%{type: "tool_use", id: id, name: name, input: input}) do
    build(id, name, input)
  end

  defp parse_one(%{"id" => id, "name" => name} = map) do
    build(id, name, Map.get(map, "arguments") || Map.get(map, "input") || %{})
  end

  defp parse_one(%{id: id, name: name} = map) do
    build(id, name, Map.get(map, :arguments) || Map.get(map, :input) || %{})
  end

  # Id-less shapes (leaked XML tool calls, hand-rolled JSON) — generate one.
  defp parse_one(%{"name" => name} = map) when not is_struct(map) do
    build(nil, name, Map.get(map, "arguments") || Map.get(map, "input") || %{})
  end

  defp parse_one(%ReqLLM.StreamChunk{type: :tool_call, name: name, arguments: args} = chunk) do
    id = chunk.metadata && (chunk.metadata["id"] || chunk.metadata[:id])
    build(id, name, args)
  end

  defp parse_one(other), do: {:error, {:unrecognised_tool_call, other}}

  defp build(_id, nil, _args), do: {:error, :missing_tool_name}

  defp build(id, name, args) do
    with {:ok, arguments} <- normalise_arguments(args) do
      {:ok,
       %ToolCall{
         id: id || generate_id(),
         name: to_string(name),
         arguments: arguments
       }}
    end
  end

  defp normalise_arguments(nil), do: {:ok, %{}}
  defp normalise_arguments(map) when is_map(map), do: {:ok, map}

  defp normalise_arguments(str) when is_binary(str) do
    trimmed = String.trim(str)

    cond do
      trimmed == "" ->
        {:ok, %{}}

      true ->
        case Jason.decode(trimmed) do
          {:ok, map} -> {:ok, map}
          {:error, _} -> Jason.decode(repair_json(trimmed))
        end
    end
  end

  defp normalise_arguments(other), do: {:error, {:invalid_arguments, other}}

  # Minimal repair for the most common small-model JSON breakage:
  # trailing commas before } or ].
  defp repair_json(str), do: Regex.replace(~r/,\s*([}\]])/, str, "\\1")

  defp fetch(map, key) when is_map(map), do: Map.get(map, key)
  defp fetch(_, _), do: nil

  defp generate_id do
    "call_" <>
      (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
