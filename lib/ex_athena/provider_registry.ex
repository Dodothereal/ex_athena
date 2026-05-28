defmodule ExAthena.ProviderRegistry do
  @moduledoc """
  GenServer that loads provider specs from `~/.config/ex_athena/providers/` at
  startup and makes them available for lookup.

  Each `.json` file in the directory defines one provider. Files that fail
  validation (missing required fields, unknown adapter, malformed JSON) are
  skipped with a warning log — a single bad file does not prevent others from
  loading.

  ## Configuration

  The directory path defaults to `~/.config/ex_athena/providers/` and can be
  overridden at startup (primarily for tests):

      start_supervised!({ExAthena.ProviderRegistry, providers_dir: "/tmp/my-dir"})

  To disable the registry in application config (e.g. during tests):

      config :ex_athena, enable_provider_registry: false

  ## Public API

      ProviderRegistry.lookup("my-ollama")
      ProviderRegistry.lookup(:"my-ollama")
      ProviderRegistry.list()
  """

  use GenServer

  require Logger

  alias ExAthena.ProviderSpec

  @default_providers_dir Path.join([System.user_home!(), ".config", "ex_athena", "providers"])

  # ── Public API ────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a provider spec by name. Accepts both atom and string names.

  Returns `{:ok, %ProviderSpec{}}` if found, `:error` otherwise.
  """
  @spec lookup(atom() | String.t()) :: {:ok, ProviderSpec.t()} | :error
  def lookup(name) when is_atom(name), do: lookup(Atom.to_string(name))

  def lookup(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:lookup, name})
  end

  @doc "Return all loaded provider specs."
  @spec list() :: [ProviderSpec.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    dir = Keyword.get(opts, :providers_dir, @default_providers_dir)
    specs = load_all(dir)
    {:ok, %{specs: specs}}
  end

  @impl GenServer
  def handle_call({:lookup, name}, _from, %{specs: specs} = state) do
    {:reply, Map.fetch(specs, name), state}
  end

  def handle_call(:list, _from, %{specs: specs} = state) do
    {:reply, Map.values(specs), state}
  end

  # ── Private helpers ───────────────────────────────────────────────

  defp load_all(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(%{}, fn file, acc ->
          path = Path.join(dir, file)

          case load_file(path) do
            {:ok, spec} ->
              Map.put(acc, spec.name, spec)

            {:error, reason} ->
              Logger.warning("ProviderRegistry: skipping #{path}: #{reason}")
              acc
          end
        end)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("ProviderRegistry: cannot read directory #{dir}: #{inspect(reason)}")
        %{}
    end
  end

  defp load_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content),
         {:ok, spec} <- ProviderSpec.from_json(json) do
      {:ok, spec}
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:error, "invalid JSON: #{Exception.message(e)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
