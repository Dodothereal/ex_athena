import Config

if config_env() == :test do
  config :ex_athena, enable_mcp: false
end

import_config "#{config_env()}.exs"

# config :ex_athena, :ollama,
#         base_url: "http://192.168.0.238:11434",
#         model: "qwen3.6:35b-a3b"
        
config :ex_athena, :llamacpp,
        base_url: "http://192.168.0.238:8181",
        model: "qwen3.6:35b-a3b"
# To use a local llama.cpp server instead:
#
#   mix athena.chat --provider llamacpp
#
# or set it as the default:
#
#   config :ex_athena, default_provider: :llamacpp
#
# config :ex_athena, :llamacpp,
#   base_url: "http://localhost:8080",
#   model: "my-model-name"
