defmodule ExAthena.Search.Result do
  @moduledoc """
  One normalized web-search hit. Backends map their provider-specific JSON/HTML
  into this shape so the `web_search` tool and the rest of the system never see
  provider details.
  """

  @enforce_keys [:title, :url]
  defstruct [:title, :url, snippet: "", score: nil, published: nil]

  @type t :: %__MODULE__{
          title: String.t(),
          url: String.t(),
          snippet: String.t(),
          score: float() | nil,
          published: String.t() | nil
        }
end

defmodule ExAthena.Search do
  @moduledoc """
  Behaviour for web-search backends.

  The `web_search` tool calls `search/2`; the concrete implementation is chosen
  via application config so the dependency on any particular search provider is
  wrapped behind a contract we own (and can mock with Mox in tests):

      config :ex_athena, :search, adapter: ExAthena.Search.Http, backend: :duckduckgo

  Mirrors the provider-resolution pattern in `ExAthena.Config` (a default module
  plus per-env override). The default adapter is `ExAthena.Search.Http`, which is
  itself pluggable across backends (DuckDuckGo / Tavily / Brave / SearXNG).
  """

  alias ExAthena.Search.Result

  @type opts :: [
          {:max_results, pos_integer()}
          | {:topic, String.t()}
          | {:recency, String.t()}
          | {:timeout_ms, pos_integer()}
        ]

  @callback search(query :: String.t(), opts()) ::
              {:ok, [Result.t()]} | {:error, term()}

  @doc "Run a web search through the configured backend."
  @spec search(String.t(), opts()) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query), do: impl().search(query, opts)

  @doc "The configured search backend module (defaults to `ExAthena.Search.Http`)."
  @spec impl() :: module()
  def impl do
    :ex_athena
    |> Application.get_env(:search, [])
    |> Keyword.get(:adapter, ExAthena.Search.Http)
  end
end
