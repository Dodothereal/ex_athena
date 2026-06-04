import Config

if config_env() == :test do
  config :ex_athena, enable_mcp: false
end

# The :claude_code provider drives the locally-installed, logged-in `claude` CLI
# (subscription/OAuth — no API key). Use the existing system binary instead of
# the SDK's default `:bundled` mode, which re-installs its own pinned CLI version
# on every session start whenever the local CLI version differs.
config :claude_code, cli_path: :global

import_config "#{config_env()}.exs"

# To use a local llama.cpp server instead:
#
#   mix athena.chat --provider llamacpp
#
# or set it as the default:
#
#   config :ex_athena, default_provider: :llamacpp
