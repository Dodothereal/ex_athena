import Config

# Disable LSP supervisor during tests so individual test cases can start
# their own isolated supervision trees via start_supervised!/1.
config :ex_athena, enable_lsp: false

# Disable sweepers that are not needed during tests.
config :ex_athena, enable_worktree_sweeper: false
config :ex_athena, enable_checkpoint_sweeper: false

# Disable ProviderRegistry at the application level so each test can start
# its own isolated instance via start_supervised!/1.
config :ex_athena, enable_provider_registry: false

# Disable implicit LSP diagnostics hook globally in tests so existing tests
# are not affected. Individual ImplicitDiagnostics tests opt back in.
config :ex_athena, lsp_implicit_diagnostics_enabled: false

# Disable request queue supervisor; individual tests opt in via start_supervised!.
config :ex_athena, :request_queue, enabled: false
