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
