defmodule ExAthena.Lsp.ServerRegistry do
  @moduledoc """
  Maps file extensions to language atoms and language atoms to LSP server
  spawn specifications.

  ## Language detection

  `language_for_path/1` inspects the file extension and returns a language
  atom, or `nil` for unknown types.

  ## Spawn specs

  `spawn_spec/1` resolves the server binary via `System.find_executable/1`
  (injectable for tests via the optional second argument) and returns
  `{:ok, %{binary: path, args: [...]}}` or `{:error, :unsupported}`.

  ## Application-env override

  Set `Application.put_env(:ex_athena, :lsp_servers, overrides)` where
  `overrides` is a map of `language_atom => %{binary: path, args: [...]}`
  to replace or disable default servers without editing source. Overridden
  specs skip `find_executable` lookup — the binary path is used as-is.
  """

  @extension_map %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".py" => :python,
    ".pyi" => :python,
    ".rs" => :rust,
    ".go" => :go,
    ".ts" => :typescript,
    ".tsx" => :typescript,
    ".js" => :typescript,
    ".jsx" => :typescript,
    ".mjs" => :typescript,
    ".cjs" => :typescript
  }

  # Default server definitions: a `{executable_name, default_args}` tuple, or a
  # LIST of such tuples tried in order (first whose binary is on PATH wins).
  #
  # Elixir prefers Expert (elixir-lang/expert), the official next-gen Elixir
  # language server, which requires the `--stdio` flag for stdio mode, and
  # falls back to ElixirLS (`elixir-ls`, no args) when `expert` is not on PATH.
  # Install Expert so an `expert` binary is on PATH (e.g. `just install` →
  # ~/.local/bin/expert), or point at a Burrito artifact via app config:
  #
  #     config :ex_athena, :lsp_servers, %{
  #       elixir: %{binary: "/path/to/expert_<os>_<arch>", args: ["--stdio"]}
  #     }
  #
  # An app-env override (above) replaces the candidate list entirely — set it
  # to `%{binary: "elixir-ls", args: []}` to pin ElixirLS.
  @default_servers %{
    elixir: [{"expert", ["--stdio"]}, {"elixir-ls", []}],
    python: {"pyright-langserver", ["--stdio"]},
    rust: {"rust-analyzer", []},
    go: {"gopls", ["serve"]},
    typescript: {"typescript-language-server", ["--stdio"]}
  }

  @doc """
  Return the language atom for the given file path based on its extension,
  or `nil` if the extension is not recognized.
  """
  @spec language_for_path(Path.t()) :: atom() | nil
  def language_for_path(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@extension_map, ext)
  end

  @doc """
  Return the spawn spec for `language`, resolving the binary via
  `find_executable` (defaults to `System.find_executable/1`).

  Returns `{:ok, %{binary: path, args: [...]}}` or `{:error, :unsupported}`.
  """
  @spec spawn_spec(atom(), (String.t() -> String.t() | nil)) ::
          {:ok, %{binary: String.t(), args: [String.t()]}} | {:error, :unsupported}
  def spawn_spec(language, find_executable \\ &System.find_executable/1) do
    overrides = Application.get_env(:ex_athena, :lsp_servers, %{})

    cond do
      Map.has_key?(overrides, language) ->
        spec = Map.fetch!(overrides, language)
        {:ok, spec}

      Map.has_key?(@default_servers, language) ->
        @default_servers
        |> Map.fetch!(language)
        |> List.wrap()
        |> resolve_candidates(find_executable)

      true ->
        {:error, :unsupported}
    end
  end

  # Try each `{executable, args}` candidate in order; the first whose binary
  # resolves on PATH wins. Returns `{:error, :unsupported}` if none resolve.
  defp resolve_candidates(candidates, find_executable) do
    Enum.find_value(candidates, {:error, :unsupported}, fn {executable, args} ->
      case find_executable.(executable) do
        nil -> false
        path -> {:ok, %{binary: path, args: args}}
      end
    end)
  end
end
