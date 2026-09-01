import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/fanfarr start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :fanfarr, FanfarrWeb.Endpoint, server: true
end

config :fanfarr, FanfarrWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :fanfarr, FanfarrWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/fanfarr_web/router\.ex$"E,
        ~r"lib/fanfarr_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Everything below is read when the container starts, not when the image is
  # built, so a single published image is configured entirely by environment.

  # The config volume. All mutable state lives here: the database, the generated
  # secret, and any caches. *arr convention is /config, and Fanfarr follows it so
  # it sits naturally next to Sonarr and Radarr in a compose file.
  config_dir = System.get_env("FANFARR_CONFIG_DIR", "/config")
  File.mkdir_p!(config_dir)

  database_path = System.get_env("DATABASE_PATH") || Path.join(config_dir, "fanfarr.db")
  File.mkdir_p!(Path.dirname(database_path))

  config :fanfarr, Fanfarr.Repo,
    database: database_path,
    # SQLite serialises writes regardless of pool size; the pool exists so
    # concurrent readers are not stuck behind the writer, which WAL makes
    # possible. See the pragmas in config/config.exs.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Phoenix needs a secret to sign cookies and sessions. Requiring the operator
  # to generate one before first run is a poor fit for an appliance, so if none
  # is supplied we generate it once and persist it beside the database. Setting
  # SECRET_KEY_BASE explicitly still wins, and rotating it just invalidates
  # existing sessions.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        secret_path = Path.join(config_dir, "secret_key_base")

        case File.read(secret_path) do
          {:ok, existing} when byte_size(existing) >= 64 ->
            String.trim(existing)

          _ ->
            generated = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
            File.write!(secret_path, generated)
            File.chmod!(secret_path, 0o600)
            generated
        end
      )

  port = String.to_integer(System.get_env("PORT") || "7373")

  bind_address =
    if System.get_env("BIND_IPV6") in ["1", "true", "yes"] do
      {0, 0, 0, 0, 0, 0, 0, 0}
    else
      {0, 0, 0, 0}
    end

  # URL generation. Defaults suit a LAN deployment reached directly by IP; set
  # these when running behind a reverse proxy so links and redirects point at
  # the public address rather than the container.
  scheme = System.get_env("URL_SCHEME") || "http"
  host = System.get_env("PHX_HOST") || "localhost"

  url_port =
    case System.get_env("URL_PORT") do
      nil -> if scheme == "https", do: 443, else: port
      value -> String.to_integer(value)
    end

  # Subpath hosting, e.g. BASE_PATH=/fanfarr behind a proxy that does not give
  # the app its own hostname.
  base_path =
    case System.get_env("BASE_PATH") do
      nil -> "/"
      "" -> "/"
      value -> "/" <> String.trim(value, "/")
    end

  config :fanfarr, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fanfarr, FanfarrWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme, path: base_path],
    http: [
      # Bind all interfaces: inside a container only the published port is
      # reachable anyway, and binding loopback would make the app unreachable
      # from outside it.
      #
      # IPv4 by default, unlike the Phoenix generator. Binding :: fails outright
      # with :eafnosupport wherever IPv6 is unavailable -- which includes Docker
      # daemons started with ipv6 disabled, a common configuration -- and the
      # failure presents as the container booting and immediately dying. Set
      # BIND_IPV6=true for a dual-stack host that needs it.
      ip: bind_address,
      port: port
    ],
    secret_key_base: secret_key_base

  # Signs authentication tokens. Same treatment as SECRET_KEY_BASE above: an
  # appliance must not require the operator to mint secrets, so one is
  # generated on first boot and persisted beside the database. Setting the
  # env var explicitly still wins; rotating it signs everyone out.
  token_signing_secret =
    System.get_env("TOKEN_SIGNING_SECRET") ||
      (
        secret_path = Path.join(config_dir, "token_signing_secret")

        case File.read(secret_path) do
          {:ok, existing} when byte_size(existing) >= 32 ->
            String.trim(existing)

          _ ->
            generated = 32 |> :crypto.strong_rand_bytes() |> Base.encode64()
            File.write!(secret_path, generated)
            File.chmod!(secret_path, 0o600)
            generated
        end
      )

  config :fanfarr, token_signing_secret: token_signing_secret
end
