defmodule Fanfarr.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FanfarrWeb.Telemetry,
      # Backs the vendored SaladUI components: they resolve Tailwind class
      # conflicts through TwMerge, which memoises results in an ETS table this
      # process owns. Without it every component render raises on a missing
      # table, so it has to start before anything can render.
      TwMerge.Cache,
      # Holds recent log lines for the System page. Started before the things
      # that log so their output is captured from the first line.
      Fanfarr.Log.Buffer,
      # Before the repo, deliberately: it migrates on a single connection of
      # its own. See the module for what a pooled migration does to SQLite.
      {Fanfarr.Repo.Migrator,
       repos: Application.fetch_env!(:fanfarr, :ecto_repos), skip: skip_migrations?()},
      Fanfarr.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:fanfarr, :ash_domains),
         # Not the raw app env: the apply queue's width is a setting, and this
         # is where a restart picks the operator's choice back up.
         Fanfarr.Jobs.oban_config()
       )},
      # Start a worker by calling: Fanfarr.Worker.start_link(arg)
      # {Fanfarr.Worker, arg},
      # Start to serve requests, typically the last entry
      # Applies AUTH_USERNAME/AUTH_PASSWORD once migrations have run. A task
      # rather than a worker: it reconciles and exits.
      {Task, &Fanfarr.Accounts.Seed.run/0},
      {DNSCluster, query: Application.get_env(:fanfarr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fanfarr.PubSub},
      # Periodic health checks for the System page and the sidebar badge.
      # Disabled in the test suite, where checks run explicitly.
      {Fanfarr.Health.Monitor, auto: Application.get_env(:fanfarr, :health_monitor, true)},
      FanfarrWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :fanfarr]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fanfarr.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Both need the tree up: the redactor reads the stored Plex token, and
        # the handler feeds a process that must already exist.
        Fanfarr.Diagnostics.Redactor.prime()
        Fanfarr.Log.Buffer.attach()
        {:ok, pid}

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FanfarrWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
