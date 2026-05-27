defmodule ExAthena.Tools do
  @moduledoc """
  Resolves tools into `ExAthena.Tool.Spec` structs for the provider and loop.

  Consumers supply tools in one of two ways:

    1. **At config time:**

           config :ex_athena, tools: [MyApp.ToolA, MyApp.ToolB]

    2. **Per-call:**

           ExAthena.Loop.run(messages, tools: [MyApp.ToolA, ExAthena.Tools.Read])

  Per-call wins; the configured list is the default when no tools are passed.

  `resolve/1` returns `[ExAthena.Tool.Spec.t()]`. Built-in modules are wrapped
  into `:module` specs; MCP-discovered tools are appended as `:mcp` specs
  (unless suppressed via `mcp: false`).
  """

  alias ExAthena.Tool
  alias ExAthena.Tool.Spec

  @builtins [
    ExAthena.Tools.Read,
    ExAthena.Tools.Glob,
    ExAthena.Tools.Grep,
    ExAthena.Tools.Write,
    ExAthena.Tools.Edit,
    ExAthena.Tools.ApplyPatch,
    ExAthena.Tools.Bash,
    ExAthena.Tools.WebFetch,
    ExAthena.Tools.TodoWrite,
    ExAthena.Tools.PlanMode,
    ExAthena.Tools.SpawnAgent,
    ExAthena.Tools.Lsp,
    ExAthena.Tools.Finish
  ]

  @doc "List the builtin tool modules."
  @spec builtins() :: [module()]
  def builtins, do: @builtins

  @doc """
  Resolve the tools to use for a call. Returns `[Tool.Spec.t()]`.

  Accepts:

    * a list of modules (each wrapped into a `:module` spec)
    * `:all` — every builtin as specs
    * `nil` — falls back to `config :ex_athena, tools: ...` or `:all`

  Options:

    * `mcp: true | false | [server_name]` — controls MCP tool inclusion.
      Defaults to `true` when the MCP supervisor is running, `false`
      otherwise. Pass `false` to suppress MCP tools entirely; pass a list
      of server names to include only tools from those servers.
  """
  @spec resolve(keyword()) :: [Spec.t()]
  def resolve(opts) do
    base_specs =
      case Keyword.get(opts, :tools) do
        nil -> Application.get_env(:ex_athena, :tools, :all) |> expand()
        :all -> @builtins
        list when is_list(list) -> list
      end
      |> Enum.map(&module_to_spec/1)

    mcp_filter = Keyword.get(opts, :mcp, mcp_default())

    mcp_specs =
      if mcp_filter == false do
        []
      else
        filter =
          case mcp_filter do
            true -> :all
            list when is_list(list) -> list
            _ -> :all
          end

        mcp_tool_specs(filter)
      end

    base_specs ++ mcp_specs
  end

  defp mcp_default do
    case Process.whereis(ExAthena.Mcp.Supervisor) do
      nil -> false
      _ -> true
    end
  end

  defp mcp_tool_specs(filter) do
    case Process.whereis(ExAthena.Mcp.Supervisor) do
      nil ->
        []

      _ ->
        ExAthena.Mcp.tool_specs(filter)
    end
  end

  defp expand(:all), do: @builtins
  defp expand(modules) when is_list(modules), do: modules
  defp expand(_), do: @builtins

  defp module_to_spec(%Spec{} = spec), do: spec

  defp module_to_spec(mod) when is_atom(mod), do: Spec.from_module(mod)

  defp module_to_spec(name) when is_binary(name) do
    case Enum.find(builtin_specs(), fn s -> s.name == name end) do
      nil -> raise ArgumentError, "no built-in tool named #{inspect(name)}"
      spec -> spec
    end
  end

  defp builtin_specs do
    case :persistent_term.get({__MODULE__, :builtin_specs}, :__none__) do
      :__none__ ->
        specs = Enum.map(@builtins, &Spec.from_module/1)
        :persistent_term.put({__MODULE__, :builtin_specs}, specs)
        specs

      specs ->
        specs
    end
  end

  @doc """
  Build the provider-facing tool schema list — the same shape Ollama /
  OpenAI-compatible providers send on the wire.
  """
  @spec describe_for_provider([Spec.t()]) :: [map()]
  def describe_for_provider(specs) do
    Enum.map(specs, fn spec ->
      %{
        type: "function",
        function: %{
          name: spec.name,
          description: spec.description,
          parameters: spec.schema
        }
      }
    end)
  end

  @doc """
  Build the prompt-friendly list used by `ExAthena.ToolCalls.augment_system_prompt/3`
  when we fall back to the TextTagged protocol.
  """
  @spec describe_for_prompt([Spec.t()]) :: [map()]
  def describe_for_prompt(specs) do
    Enum.map(specs, fn spec ->
      %{name: spec.name, description: spec.description, schema: spec.schema}
    end)
  end

  @doc "Find the spec that handles a call by name."
  @spec find([Spec.t()], String.t()) :: Spec.t() | nil
  def find(specs, name) when is_binary(name) do
    Enum.find(specs, fn spec -> spec.name == name end)
  end

  @doc "Validate a list of specs. Raises if any module spec's module doesn't implement the Tool behaviour."
  @spec validate!([Spec.t()]) :: :ok
  def validate!(specs) do
    Enum.each(specs, fn
      %Spec{kind: :module, module: mod} ->
        unless Code.ensure_loaded?(mod) and implements_behaviour?(mod, Tool) do
          raise ArgumentError, "#{inspect(mod)} does not implement ExAthena.Tool"
        end

      %Spec{kind: :mcp} ->
        :ok
    end)

    :ok
  end

  defp implements_behaviour?(mod, behaviour) do
    behaviours = mod.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    behaviour in behaviours
  end
end
