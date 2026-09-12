defmodule Fanfarr.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before anything else logs a timestamp. It is one line, and it is the only
    # way a TZ that did not resolve announces itself -- glibc uses UTC for a
    # zone it cannot find without a word.
    Fanfarr.Clock.log_zone()

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
      # After the repo, and after the migrator that runs before it: this one
      # writes the captured log to a table, so both have to exist first. The
      # buffer above starts earlier on purpose and simply does not persist the
      # handful of lines logged before this point.
      Fanfarr.Log.Store,
      # An MFA, not `{Oban, AshOban.config(...)}`. This list is a literal: every
      # element is evaluated when the list is built, which is before any child
      # has started. Written the obvious way, the apply queue's width was read
      # out of the database before Fanfarr.Repo existed -- the read failed, the
      # resolver's `_ -> nil` swallowed it, and Oban started at the compiled
      # default of 2 while Settings went on displaying the 4 the operator had
      # chosen. It only showed up after a restart, because scaling the running
      # queue works fine. Supervisor calls this after the children before it
      # are up, so the setting is there to be read.
      %{id: Oban, type: :supervisor, start: {Fanfarr.Jobs, :start_oban, []}},
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
