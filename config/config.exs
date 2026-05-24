import Config

if config_env() == :test do
  config :ex_athena, enable_mcp: false
end

import_config "#{config_env()}.exs"

# To use a local llama.cpp server instead:
#
#   mix athena.chat --provider llamacpp
#
# or set it as the default:
#
#   config :ex_athena, default_provider: :llamacpp
