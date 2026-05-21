defmodule ExAthena.Web.Sessions do
  @moduledoc """
  Simple file-based session persistence for the web UI.

  Sessions are stored as Erlang term binaries under ~/.ex_athena/web/sessions/.
  Each session includes the display message list (for rendering) and the
  canonical ExAthena message list (for replaying / forking).
  """

  @session_dir Path.expand("~/.ex_athena/web/sessions")

  @doc "List session headers sorted newest-first."
  @spec list() :: [map()]
  def list do
    dir = session_dir()
    File.mkdir_p!(dir)

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".session"))
    |> Enum.flat_map(fn file ->
      case read_header(Path.join(dir, file)) do
        {:ok, header} -> [header]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @doc "Persist a session map. Overwrites if the id already exists."
  @spec save(map()) :: :ok
  def save(%{id: id} = data) do
    dir = session_dir()
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{id}.session"), :erlang.term_to_binary(data))
  end

  @doc "Load a full session by id."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(id) do
    path = Path.join(session_dir(), "#{id}.session")

    case File.read(path) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin, [:safe])}
      {:error, _} = err -> err
    end
  end

  @doc "Delete a session file."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    File.rm(Path.join(session_dir(), "#{id}.session"))
  end

  defp session_dir, do: @session_dir

  defp read_header(path) do
    with {:ok, bin} <- File.read(path),
         data when is_map(data) <- :erlang.binary_to_term(bin, [:safe]) do
      {:ok, Map.take(data, [:id, :title, :provider, :model, :mode, :updated_at])}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
