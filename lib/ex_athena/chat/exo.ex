defmodule ExAthena.Chat.Exo do
  @moduledoc """
  Talks to a local exo cluster's HTTP API (https://github.com/exo-explore/exo)
  for chat-time helpers.

  `list_models/1` is a deprecated shim over `ExAthena.list_models(:exo)` — the
  `GET /v1/models?status=downloaded` transport now lives in
  `ExAthena.ModelListing` with every other backend's. It still returns the ids
  downloaded somewhere in the cluster, sorted alphabetically; exo model ids are
  full HuggingFace ids (e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit`).

  `ensure_instance/2` guarantees the model has an active instance before a chat
  request: exo returns 404 ("No instance found for model …") otherwise. Because
  `POST /place_instance` is NOT idempotent (it creates duplicate instances), we
  check `GET /state/instances` first and only place when absent, then poll state
  until the instance registers (sub-second in practice; weight loading happens
  after registration and only affects first-token latency).
  """

  alias ExAthena.ModelListing

  @default_base_url "http://localhost:52415"
  @timeout_ms 2_000
  @default_poll_interval_ms 250
  @default_instance_timeout_ms 10_000

  @deprecated "Use ExAthena.list_models(:exo) instead"
  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :exo_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    [
      openai_compatible_backend: :exo,
      base_url: Keyword.get(opts, :base_url, configured_base_url()),
      timeout_ms: @timeout_ms
    ]
    |> ModelListing.list()
    |> ModelListing.legacy_result()
  end

  @doc """
  Guarantees `model` has an active instance in the exo cluster, placing one
  if absent and polling until it registers.

  Options: `:base_url`, `:poll_interval_ms` (default 250), `:timeout_ms`
  (default 10_000). The timeout is approximate (a lower bound): each poll adds
  up to one HTTP round-trip beyond the deadline.
  """
  @spec ensure_instance(String.t(), keyword()) ::
          :ok
          | {:error,
             :exo_unreachable
             | :exo_instance_unavailable
             | :unexpected_response
             | {:http, integer()}}
  def ensure_instance(model, opts \\ []) when is_binary(model) do
    base = opts |> Keyword.get(:base_url, configured_base_url()) |> strip_v1_suffix()

    # Serialize concurrent callers per model within this node: both could
    # otherwise observe "absent" and double-place (/place_instance is not
    # idempotent). Callers in other OS processes can still race; acceptable
    # for a single-user local server.
    :global.trans({{__MODULE__, model}, self()}, fn ->
      case fetch_instance_presence(base, model) do
        {:ok, true} -> :ok
        {:ok, false} -> place_and_await(base, model, opts)
        {:error, _} = err -> err
      end
    end)
  end

  defp fetch_instance_presence(base, model) do
    case Req.get(base <> "/state/instances", receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_instance_presence(body, model)
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, _} -> {:error, :exo_unreachable}
    end
  end

  # Instances are a map of id => tagged union, e.g.
  # %{"<uuid>" => %{"MlxRingInstance" => %{"shardAssignments" => %{"modelId" => m}}}}.
  # The tag key varies (MlxRingInstance | MlxJacclInstance), so match any tag.
  defp decode_instance_presence(body, model) when is_map(body) do
    active? =
      Enum.any?(body, fn {_id, tagged} ->
        is_map(tagged) and
          Enum.any?(tagged, fn
            {_tag, %{"shardAssignments" => %{"modelId" => ^model}}} -> true
            _ -> false
          end)
      end)

    {:ok, active?}
  end

  defp decode_instance_presence(body, model) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_instance_presence(decoded, model)
      {:error, _} -> {:error, :unexpected_response}
    end
  end

  defp decode_instance_presence(_, _), do: {:error, :unexpected_response}

  defp place_and_await(base, model, opts) do
    url = base <> "/place_instance"

    case Req.post(url,
           json: %{"model_id" => model},
           receive_timeout: @timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} ->
        interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
        timeout = Keyword.get(opts, :timeout_ms, @default_instance_timeout_ms)
        deadline = System.monotonic_time(:millisecond) + timeout
        await_instance(base, model, interval, deadline)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, _} ->
        {:error, :exo_unreachable}
    end
  end

  defp await_instance(base, model, interval, deadline) do
    case fetch_instance_presence(base, model) do
      {:ok, true} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :exo_instance_unavailable}
        else
          Process.sleep(interval)
          await_instance(base, model, interval, deadline)
        end
    end
  end

  defp configured_base_url do
    :ex_athena
    |> Application.get_env(:exo, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp strip_v1_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end
end
