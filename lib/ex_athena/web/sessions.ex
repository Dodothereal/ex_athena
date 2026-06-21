defmodule ExAthena.Web.Sessions do
  @moduledoc """
  File-based session persistence for the web UI.

  Sessions are stored as Erlang term binaries under ~/.ex_athena/web/sessions/.
  A compact JSON index at ~/.ex_athena/web/recent.json tracks the most recently
  opened working directories so users can jump back to a project quickly.
  """

  @base_dir Path.expand("~/.ex_athena/web")
  @sessions_dir Path.join(@base_dir, "sessions")
  @recent_path Path.join(@base_dir, "recent.json")
  @max_recent 20

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc "List all session headers, newest first."
  @spec list() :: [map()]
  def list do
    dir = sessions_dir()

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".session"))
    |> Enum.flat_map(fn file ->
      case read_header(Path.join(dir, file)) do
        {:ok, h} -> [h]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @doc "List session headers for a specific working directory, newest first."
  @spec list_for_cwd(String.t()) :: [map()]
  def list_for_cwd(cwd) do
    list() |> Enum.filter(&(&1[:cwd] == cwd))
  end

  @doc "Persist a session. Overwrites if the id already exists."
  @spec save(map()) :: :ok
  def save(%{id: id} = data) do
    dir = sessions_dir()
    File.write!(Path.join(dir, "#{id}.session"), :erlang.term_to_binary(data))
  end

  @doc """
  Durably append a completed run's final assistant message to its session.

  Used by the run task so the answer survives even when the LiveView process
  that started the run has died (e.g. a websocket reconnect mid-run sends the
  final `{:athena_done, result}` to a now-dead pid). Load-modify-save, and
  **idempotent by `msg_id`** — a no-op if the LiveView already persisted that
  message, so the LiveView's richer (tool-event-bearing) version is preserved.
  """
  @spec append_run_result(String.t(), String.t(), map(), map()) :: :ok
  def append_run_result(session_id, msg_id, assistant_msg, result) do
    case load(session_id) do
      {:ok, data} ->
        case merge_run_result(data, msg_id, assistant_msg, result) do
          {:save, merged} -> save(merged)
          :skip -> :ok
        end

      # No session file yet (never saved) — nothing to attach to.
      {:error, _} ->
        :ok
    end
  end

  @doc false
  @spec merge_run_result(map(), String.t(), map(), map()) :: {:save, map()} | :skip
  def merge_run_result(data, msg_id, assistant_msg, result) do
    msgs = Map.get(data, :display_messages, [])

    if Enum.any?(msgs, &(&1.id == msg_id)) do
      :skip
    else
      {:save,
       data
       |> Map.put(:display_messages, msgs ++ [assistant_msg])
       |> Map.put(:ex_messages, result.messages || Map.get(data, :ex_messages, []))
       |> Map.put(:provider_session_id, result.session_id || Map.get(data, :provider_session_id))
       |> Map.put(:updated_at, DateTime.utc_now())}
    end
  end

  @doc """
  The chat message text for a finished run, surfacing the `finish` deliverable
  so the submitted answer is always visible in the main chat.

  When the run ended via `finish` (`finish_reason: :submitted`) with a
  deliverable: it becomes the message text if nothing was streamed (the
  orchestrator delegated and only submitted a deliverable), or is appended to
  the streamed text otherwise — unless that text already contains it. Any other
  termination keeps the streamed text unchanged.
  """
  @spec final_message_text(String.t(), ExAthena.Result.t()) :: String.t()
  def final_message_text(stream_text, %{finish_reason: :submitted, deliverable: d})
      when is_binary(d) and d != "" do
    cond do
      String.trim(stream_text) == "" -> d
      String.contains?(stream_text, String.trim(d)) -> stream_text
      true -> stream_text <> "\n\n" <> d
    end
  end

  def final_message_text(stream_text, _result), do: stream_text

  @doc """
  Build a run's final assistant message from the `Result` alone (no live UI
  state) and durably append it to the session. The durable path for when the
  process that owns the run wants the answer saved regardless of whether a
  LiveView is currently attached. Idempotent by `msg_id` (see
  `append_run_result/4`).
  """
  @spec persist_run_result(String.t(), String.t(), ExAthena.Result.t()) :: :ok
  def persist_run_result(session_id, msg_id, result) do
    usage = result.usage || %{}

    status = %{
      iterations: result.iterations || 0,
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      cost_usd: result.cost_usd || 0.0
    }

    msg = %{
      id: msg_id,
      role: :assistant,
      text: final_message_text(to_string(result.text || ""), result),
      tool_events: [],
      status: status,
      ex_snapshot: result.messages
    }

    append_run_result(session_id, msg_id, msg, result)
  rescue
    _ -> :ok
  end

  @doc "Load a full session by id."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(id) do
    path = Path.join(sessions_dir(), "#{id}.session")

    case File.read(path) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin)}
      {:error, _} = err -> err
    end
  end

  @doc "Delete a session file."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    File.rm(Path.join(sessions_dir(), "#{id}.session"))
  end

  # ---------------------------------------------------------------------------
  # Recently opened working directories
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of recently opened working directories, newest first.
  Each entry: %{cwd: path, name: basename, opened_at: DateTime.t()}
  """
  @spec list_recent() :: [map()]
  def list_recent do
    case File.read(@recent_path) do
      {:ok, json} ->
        json
        |> Jason.decode!(keys: :atoms)
        |> Enum.map(fn entry ->
          opened_at =
            case DateTime.from_iso8601(entry.opened_at) do
              {:ok, dt, _} -> dt
              _ -> DateTime.utc_now()
            end

          %{cwd: entry.cwd, name: Path.basename(entry.cwd), opened_at: opened_at}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Record a working directory as recently opened (deduplicates, caps at #{@max_recent})."
  @spec touch_recent(String.t()) :: :ok
  def touch_recent(cwd) do
    existing = list_recent()

    updated =
      [%{cwd: cwd, name: Path.basename(cwd), opened_at: DateTime.utc_now()} | existing]
      |> Enum.uniq_by(& &1.cwd)
      |> Enum.take(@max_recent)

    payload =
      Enum.map(updated, fn e ->
        %{cwd: e.cwd, opened_at: DateTime.to_iso8601(e.opened_at)}
      end)

    File.mkdir_p!(@base_dir)
    File.write!(@recent_path, Jason.encode!(payload))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Remove a working directory from the recent list."
  @spec remove_recent(String.t()) :: :ok
  def remove_recent(cwd) do
    updated = list_recent() |> Enum.reject(&(&1.cwd == cwd))

    payload =
      Enum.map(updated, fn e ->
        %{cwd: e.cwd, opened_at: DateTime.to_iso8601(e.opened_at)}
      end)

    File.mkdir_p!(@base_dir)
    File.write!(@recent_path, Jason.encode!(payload))
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp sessions_dir do
    File.mkdir_p!(@sessions_dir)
    @sessions_dir
  end

  defp read_header(path) do
    with {:ok, bin} <- File.read(path),
         data when is_map(data) <- :erlang.binary_to_term(bin) do
      {:ok, Map.take(data, [:id, :title, :cwd, :provider, :model, :mode, :updated_at])}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
