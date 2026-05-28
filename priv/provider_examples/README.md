# Provider Examples

Copy any file from this directory to `~/.config/ex_athena/providers/` and set
the environment variable named in `api_key_env` — ExAthena will load the
provider automatically at startup with no changes to `config/config.exs`. Each
file is a minimal valid JSON spec; add `default_model` or any other optional
field to customise. See the [Providers guide](../../guides/providers.md#runtime-json-config)
for the full schema reference and security recommendations.

- **[openrouter.json](openrouter.json)** — OpenRouter gateway; routes to hundreds of models from Anthropic, Google, Meta, and Mistral through a single endpoint.
- **[groq.json](groq.json)** — Groq LPU inference; ultra-low-latency open-source models including Llama 3.3 and Mixtral.
- **[together.json](together.json)** — Together AI; broad catalog of hosted open-source models with optional fine-tuning support.
- **[fireworks.json](fireworks.json)** — Fireworks AI; fast serverless inference for popular open-source models.
- **[deepseek.json](deepseek.json)** — DeepSeek; cost-effective inference for DeepSeek-series models including the reasoning variant.
