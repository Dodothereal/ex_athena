defmodule ExAthena.Providers.Mock do
  @moduledoc """
  In-memory provider for tests.

  Scripted responses either by canned text or by a user-supplied responder
  function. No external dependency — use in unit tests that want to exercise
  the agent loop / tool-call parsers without standing up a fake HTTP server.

  ## Usage

  Pass a scripted response per call:

      ExAthena.query("ping", provider: :mock, mock: [text: "pong"])

  Or a responder function for dynamic behaviour:

      responder = fn request ->
        %ExAthena.Response{text: "echo: " <> hd(request.messages).content}
      end
      ExAthena.query("hi", provider: :mock, mock: [responder: responder])

  For streaming, supply a list of events under `:mock_events`:

      events = [
        %ExAthena.Streaming.Event{type: :text_delta, data: "Hello"},
        %ExAthena.Streaming.Event{type: :text_delta, data: " world"},
        %ExAthena.Streaming.Event{type: :stop, data: :stop}
      ]
      ExAthena.stream("hi", fn _ -> :ok end,
        provider: :mock,
        mock: [text: "Hello world"],
        mock_events: events)
  """

  @behaviour ExAthena.Provider

  alias ExAthena.{Embedding, Response, Streaming}
  alias ExAthena.Streaming.Event

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: true,
      streaming: true,
      embeddings: true,
      json_mode: true,
      structured_output: true,
      max_tokens: 128_000,
      supports_resume: false,
      supports_system_prompt: true,
      supports_temperature: true
    }
  end

  @impl ExAthena.Provider
  def query(request, opts) do
    mock = Keyword.get(opts, :mock, [])

    cond do
      responder = Keyword.get(mock, :responder) ->
        try do
          {:ok, responder.(request)}
        rescue
          e -> {:error, {:mock_raised, e}}
        end

      text = Keyword.get(mock, :text) ->
        {:ok,
         %Response{
           text: text,
           thinking: Keyword.get(mock, :thinking),
           tool_calls: Keyword.get(mock, :tool_calls, []),
           finish_reason: :stop,
           model: request.model,
           provider: :mock,
           usage: Keyword.get(mock, :usage),
           raw: %{mock: true}
         }}

      error = Keyword.get(mock, :error) ->
        {:error, error}

      true ->
        {:error, :mock_not_configured}
    end
  end

  @impl ExAthena.Provider
  def embed(input, opts) do
    mock = Keyword.get(opts, :mock, [])
    texts = List.wrap(input)

    cond do
      responder = Keyword.get(mock, :embed_responder) ->
        try do
          {:ok, embedding(responder.(texts), opts)}
        rescue
          e -> {:error, {:mock_raised, e}}
        end

      vectors = Keyword.get(mock, :embeddings) ->
        {:ok, embedding(vectors, opts)}

      error = Keyword.get(mock, :error) ->
        {:error, error}

      true ->
        {:error, :mock_not_configured}
    end
  end

  defp embedding(vectors, opts) do
    %Embedding{
      embeddings: vectors,
      model: Keyword.get(opts, :model),
      provider: :mock,
      usage: Keyword.get(opts, :mock, [])[:usage],
      raw: %{mock: true}
    }
  end

  @impl ExAthena.Provider
  def stream(request, callback, opts) do
    events = Keyword.get(opts, :mock_events, [])

    Enum.each(events, fn
      %Event{} = event -> callback.(event)
      tuple when is_tuple(tuple) -> callback.(tuple_to_event(tuple))
    end)

    # If no explicit stop, emit one.
    unless stop_event?(events) do
      Streaming.stop(callback, :stop)
    end

    query(request, opts)
  end

  defp stop_event?(events) do
    Enum.any?(events, fn
      %Event{type: :stop} -> true
      {:stop, _} -> true
      _ -> false
    end)
  end

  defp tuple_to_event({type, data}), do: %Event{type: type, data: data}
end
