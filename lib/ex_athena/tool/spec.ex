defmodule ExAthena.Tool.Spec do
  @moduledoc """
  Canonical, unified representation of a tool — whether backed by a
  behaviour-implementing module or a dynamically-discovered MCP tool.

  ## Kinds

    * `:module` — wraps a module that implements `ExAthena.Tool`. All fields
      are populated from the module's callbacks at construction time.
    * `:mcp` — wraps a tool discovered from an MCP server. The tool name is
      namespaced as `"<server>_<tool>"`. MCP tools are never assumed
      parallel-safe.

  ## Construction

      spec = ExAthena.Tool.Spec.from_module(MyApp.ReadTool)
      spec = ExAthena.Tool.Spec.from_mcp(tool_map, "myserver")

  ## Dispatch

      ExAthena.Tool.Spec.execute(spec, args, ctx)
  """

  alias ExAthena.ToolContext

  @type kind :: :module | :mcp

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: map(),
          parallel_safe?: boolean(),
          read_only?: boolean(),
          kind: kind(),
          module: module() | nil,
          mcp_server: String.t() | nil,
          mcp_tool_name: String.t() | nil
        }

  defstruct [
    :name,
    :description,
    :schema,
    :parallel_safe?,
    :kind,
    :module,
    :mcp_server,
    :mcp_tool_name,
    read_only?: false
  ]

  @doc "Build a spec from a module implementing `ExAthena.Tool`."
  @spec from_module(module()) :: t()
  def from_module(mod) when is_atom(mod) do
    unless Code.ensure_loaded?(mod) do
      raise ArgumentError, "#{inspect(mod)} cannot be loaded"
    end

    unless tool_module?(mod) do
      raise ArgumentError, "#{inspect(mod)} does not implement ExAthena.Tool"
    end

    parallel_safe =
      function_exported?(mod, :parallel_safe?, 0) and mod.parallel_safe?()

    read_only =
      function_exported?(mod, :read_only?, 0) and mod.read_only?()

    %__MODULE__{
      name: mod.name(),
      description: mod.description(),
      schema: mod.schema(),
      parallel_safe?: parallel_safe,
      read_only?: read_only,
      kind: :module,
      module: mod,
      mcp_server: nil,
      mcp_tool_name: nil
    }
  end

  defp tool_module?(mod) do
    function_exported?(mod, :name, 0) and
      function_exported?(mod, :description, 0) and
      function_exported?(mod, :schema, 0) and
      function_exported?(mod, :execute, 2)
  end

  @doc """
  Build a spec from an MCP tool map and server name.

  `tool_map` is a map with string keys `"name"`, `"description"`, and
  `"inputSchema"` as returned by `tools/list`. The resulting spec's `:name`
  is `"<server>_<tool>"`.
  """
  @spec from_mcp(map(), String.t()) :: t()
  def from_mcp(%{"name" => tool_name} = tool_map, server_name)
      when is_binary(tool_name) and is_binary(server_name) do
    %__MODULE__{
      name: "#{server_name}_#{tool_name}",
      description: Map.get(tool_map, "description", ""),
      schema: Map.get(tool_map, "inputSchema", %{}),
      parallel_safe?: false,
      # MCP's standard read-only declaration (`annotations.readOnlyHint`).
      # A hint from the server, not a guarantee — it gates the `:plan`
      # phase's deny-by-default, nothing stronger.
      read_only?: get_in(tool_map, ["annotations", "readOnlyHint"]) == true,
      kind: :mcp,
      module: nil,
      mcp_server: server_name,
      mcp_tool_name: tool_name
    }
  end

  @doc """
  Execute the tool with `args` and `ctx`.

  Dispatches to `module.execute/2` for `:module` specs, and to
  `ExAthena.Mcp.Tool.execute/3` for `:mcp` specs.
  """
  @spec execute(t(), map(), ToolContext.t()) ::
          {:ok, term()} | {:error, term()} | {:halt, term()}
  def execute(%__MODULE__{kind: :module, module: mod}, args, ctx) do
    mod.execute(args, ctx)
  end

  def execute(%__MODULE__{kind: :mcp} = spec, args, ctx) do
    ExAthena.Mcp.Tool.execute(spec, args, ctx)
  end

  @doc "Return the cached `parallel_safe?` flag."
  @spec parallel_safe?(t()) :: boolean()
  def parallel_safe?(%__MODULE__{parallel_safe?: val}), do: val
end
