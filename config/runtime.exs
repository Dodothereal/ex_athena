import Config

# Web search backend, configured from the environment at runtime so deploys can
# pick a provider without a recompile. The default (no env set) is DuckDuckGo,
# which needs neither a key nor an endpoint.
#
#   EX_ATHENA_SEARCH_BACKEND   :duckduckgo (default) | tavily | brave | searxng
#   EX_ATHENA_SEARCH_API_KEY   required for tavily / brave
#   EX_ATHENA_SEARCH_ENDPOINT  required for searxng; optional override otherwise
#
# Skipped in :test, where config/test.exs points the adapter at the Mox mock.
if config_env() != :test do
  backend =
    System.get_env("EX_ATHENA_SEARCH_BACKEND", "duckduckgo")
    |> String.to_existing_atom()

  config :ex_athena, :search,
    adapter: ExAthena.Search.Http,
    backend: backend,
    api_key: System.get_env("EX_ATHENA_SEARCH_API_KEY"),
    endpoint: System.get_env("EX_ATHENA_SEARCH_ENDPOINT")
end
