import Config
config :fanfarr, token_signing_secret: "o8cnUUkYDa/PB6VPPGgjIhoRZFy6E2nK"
config :bcrypt_elixir, log_rounds: 1
config :fanfarr, Oban, testing: :manual
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fanfarr, Fanfarr.Repo,
  database: Path.expand("../fanfarr_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fanfarr, FanfarrWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xPu30wT7pMYDs52CQ5fsp5M7Lu1axoT0grJHWnaZ+9FttF8MBcBe+BnFoxe0/Vrg",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
