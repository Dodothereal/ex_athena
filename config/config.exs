import Config

if config_env() == :test do
  config :ex_athena, enable_mcp: false
end

import_config "#{config_env()}.exs"
