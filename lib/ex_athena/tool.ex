defmodule ExAthena.Tool do
  @moduledoc """
  Behaviour every tool must implement.

  Tools are stateless modules. The agent loop handles lifecycle, permissions,
  and result replay — tools only need to execute against a `ToolContext`.

  ## Implementing a tool

      defmodule MyApp.DescribePage do
        @behaviour ExAthena.Tool

        @impl true
        def name, do: "describe_page"

        @impl true
        def description, do: "Summarise the content of a web page"

        @impl true
        def schema do
          %{
            type: "object",
            properties: %{url: %{type: "string"}},
            required: ["url"]
          }
        end

        @impl true
        def execute(%{"url" => url}, _ctx) do
          # … your work here
          {:ok, "summary of " <> url}
        end
      end

  Register it either at config time (`config :ex_athena, tools: [...]`) or by
  passing it through `ExAthena.Loop.run/2` as part of the `:tools` option.

  ## Return shapes

    * `{:ok, result}` — result is stringified and replayed to the model as a
      tool-result message.
    * `{:error, reason}` — replayed as an error tool-result so the model can
      decide what to do next.
    * `{:halt, reason}` — escape hatch; loop stops immediately. Reserve for
      hard failures (session ended, budget exceeded, etc.).
  """

  alias ExAthena.ToolContext

  @callback name() :: String.t()
  @callback description() :: String.t()

  @doc """
  JSON schema for the tool's arguments. Used by providers that support native
  tool calls AND by the TextTagged prompt augmenter.
  """
  @callback schema() :: map()

  @callback execute(arguments :: map(), ctx :: ToolContext.t()) ::
              {:ok, result :: term()}
              | {:error, reason :: term()}
              | {:halt, reason :: term()}

  @doc """
  Whether this tool is safe to run concurrently with siblings in the same
  iteration.

  Read-only tools (Read, Glob, Grep, WebFetch) return `true`. Mutating
  tools (Write, Edit, Bash, TodoWrite) MUST return `false` so the loop
  preserves their ordering.

  Defaults to `false` (conservative) when the callback isn't implemented.
  """
  @callback parallel_safe?() :: boolean()

  @doc """
  Whether this tool is read-only — it never mutates the workspace,
  filesystem, or any external system.

  The `:plan` (read-only) permission phase denies every tool it does not
  know to be read-only. Custom tools that are genuinely read-only opt in
  by returning `true` here; MCP tools opt in via the standard
  `annotations.readOnlyHint` on their `tools/list` entry.

  Defaults to `false` (conservative) when the callback isn't implemented —
  an undeclared custom tool is treated as mutating and blocked in `:plan`.
  """
  @callback read_only?() :: boolean()

  @optional_callbacks [parallel_safe?: 0, read_only?: 0]
end
