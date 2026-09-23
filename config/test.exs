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
  # Raised for the async tests, which own a connection each.
  pool_size: 10,
  # A non-async test shares one connection with every process in it -- see
  # `Fanfarr.DataCase.setup_sandbox/1` -- so a request queues behind whatever
  # else is talking to the database: the scheduler, a LiveView, an async task.
  # DBConnection drops a request from that queue once the average wait passes
  # queue_target, and the defaults are tight enough that a slow test surfaced as
  # "connection not available and request was dropped from queue after 4804ms",
  # failing whichever tests happened to be running anywhere near it. Nothing is
  # short of writers here, it is short of patience, so the wait is what is
  # raised. See the SQLite note in config/config.exs for the lock half.
  queue_target: 10_000,
  queue_interval: 20_000,
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

config :fanfarr, req_options: [plug: {Req.Test, Fanfarr.PlexReq}]
config :fanfarr, health_monitor: false

# The refresh read-back polls the server; there is nothing to wait for when the
# client is a mock.
config :fanfarr, plex_theme_poll_delays: [0, 0]
