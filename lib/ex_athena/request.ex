defmodule ExAthena.Request do
  @moduledoc """
  A normalised inference request.

  Every provider receives an `ExAthena.Request` and is responsible for mapping
  it to its own wire format. Keeping the shared shape here means callers don't
  need to think about whether they're talking to Ollama, OpenAI, or Claude.
  """

  alias ExAthena.Messages
  alias ExAthena.Messages.{ContentPart, Message}

  @enforce_keys [:messages]
  defstruct [
    :messages,
    :model,
    :system_prompt,
    :max_tokens,
    :temperature,
    :top_p,
    :stop,
    :timeout_ms,
    :tools,
    :tool_choice,
    :response_format,
    :provider_opts,
    :metadata
  ]

  @type t :: %__MODULE__{
          messages: [Message.t()],
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          max_tokens: pos_integer() | nil,
          temperature: float() | nil,
          top_p: float() | nil,
          stop: [String.t()] | String.t() | nil,
          timeout_ms: pos_integer() | nil,
          tools: [map()] | nil,
          tool_choice: :auto | :any | :none | map() | nil,
          response_format: :text | :json | map() | nil,
          provider_opts: keyword() | nil,
          metadata: map() | nil
        }

  @doc """
  Build a request from a raw user prompt and options.

  The prompt is prepended to `opts[:messages]` as a user message. Pass `nil`
  to start from a pre-built message list.

  ## Images shorthand

  Pass `images: [%{data: binary(), media_type: String.t()}]` to attach inline
  images to the trailing user message. Each entry may also use
  `%{url: String.t()}` for remote image URLs. When a non-empty prompt is
  given, a multimodal user message is built with the text first followed by
  image parts. When prompt is `nil` or `""`, image parts are merged into the
  last user message in `:messages`, or appended as a new user message.
  """
  @spec new(String.t() | nil, keyword()) :: t()
  def new(prompt, opts) do
    existing = opts |> Keyword.get(:messages, []) |> Enum.map(&Messages.from_map/1)
    image_parts = opts |> Keyword.get(:images, []) |> normalize_images()
    messages = build_messages(prompt, existing, image_parts)

    %__MODULE__{
      messages: messages,
      model: Keyword.get(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_tokens: Keyword.get(opts, :max_tokens),
      temperature: Keyword.get(opts, :temperature),
      top_p: Keyword.get(opts, :top_p),
      stop: Keyword.get(opts, :stop),
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
      tools: Keyword.get(opts, :tools),
      tool_choice: Keyword.get(opts, :tool_choice),
      response_format: Keyword.get(opts, :response_format),
      provider_opts: Keyword.get(opts, :provider_opts),
      metadata: Keyword.get(opts, :metadata)
    }
  end

  # No images — existing behavior unchanged
  defp build_messages(nil, existing, []), do: existing
  defp build_messages("", existing, []), do: existing
  defp build_messages(str, existing, []) when is_binary(str), do: existing ++ [Messages.user(str)]

  # Non-empty prompt + images → multimodal user message (text first, then images)
  defp build_messages(str, existing, image_parts) when is_binary(str) and str != "" do
    existing ++ [Messages.user([ContentPart.text(str) | image_parts])]
  end

  # No prompt (nil or "") + images → merge into last user message or append new one
  defp build_messages(_prompt, existing, image_parts) do
    case find_last_user(existing) do
      {before, %Message{content: text} = msg, after_msgs} when is_binary(text) ->
        before ++ [%{msg | content: [ContentPart.text(text) | image_parts]}] ++ after_msgs

      {before, %Message{content: parts} = msg, after_msgs} when is_list(parts) ->
        before ++ [%{msg | content: parts ++ image_parts}] ++ after_msgs

      {before, %Message{} = msg, after_msgs} ->
        before ++ [%{msg | content: image_parts}] ++ after_msgs

      :none ->
        existing ++ [Messages.user(image_parts)]
    end
  end

  defp normalize_images([]), do: []

  defp normalize_images(images) do
    Enum.map(images, fn
      %{url: url} ->
        ContentPart.image_url(url)

      %{data: data, media_type: media_type} ->
        ContentPart.image(data, media_type)

      %{data: data} ->
        ContentPart.image(data, "image/png")

      other ->
        raise ArgumentError,
              "invalid image spec #{inspect(other)}; expected %{data: binary(), media_type: String.t()}, %{data: binary()}, or %{url: String.t()}"
    end)
  end

  defp find_last_user(messages) do
    reversed = Enum.reverse(messages)

    case Enum.split_while(reversed, fn m -> m.role != :user end) do
      {_suffix, []} ->
        :none

      {suffix_rev, [last_user | rest_rev]} ->
        {Enum.reverse(rest_rev), last_user, Enum.reverse(suffix_rev)}
    end
  end
end
