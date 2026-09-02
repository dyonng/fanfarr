# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash_oban, pro?: false

config :fanfarr, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  # :themerrdb is deliberately narrow -- ~2,550 cold-sync requests against a
  # community-run static host deserve restraint, not throughput.
  # `apply` is deliberately narrow: each job downloads audio and writes to
  # someone's media drive, and there is no hurry.
  queues: [default: 10, sync: 3, themerrdb: 2, apply: 2],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {1, :day}],
  repo: Fanfarr.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

# SQLite connection tuning.
#
# SQLite allows exactly one writer at a time. WAL mode lets readers continue
# concurrently with that writer instead of blocking, which is what makes a
# dashboard usable while a library sync is running. busy_timeout gives a
# blocked writer time to acquire the lock rather than failing immediately --
# without it, concurrent job workers surface SQLITE_BUSY as job errors.
#
# The corollary is a design rule, not a setting: never hold a transaction open
# across HTTP. A yt-dlp fetch or a Plex upload takes minutes and would block
# every other write for its duration. Write intent, commit, do the IO, then
# write the outcome.
#
# Note: `PRAGMA busy_timeout` reads back 0 even when this is set. exqlite
# installs a custom busy handler and applies the timeout through its own NIF
# rather than the pragma, because the pragma would destroy that handler
# (deps/exqlite/lib/exqlite/connection.ex). The readback is not a way to
# verify this setting.
config :fanfarr, Fanfarr.Repo,
  journal_mode: :wal,
  busy_timeout: 15_000,
  synchronous: :normal,
  foreign_keys: :on,
  cache_size: -64_000,
  temp_store: :memory

config :fanfarr,
  ecto_repos: [Fanfarr.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Fanfarr.Accounts, Fanfarr.Library, Fanfarr.Themes, Fanfarr.Settings]

# Configure the endpoint
config :fanfarr, FanfarrWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FanfarrWeb.ErrorHTML, json: FanfarrWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fanfarr.PubSub,
  live_view: [signing_salt: "TIaRa7Ba"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  fanfarr: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  fanfarr: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
