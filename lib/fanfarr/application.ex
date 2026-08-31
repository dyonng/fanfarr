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
      Fanfarr.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:fanfarr, :ecto_repos), skip: skip_migrations?()},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:fanfarr, :ash_domains),
         Application.fetch_env!(:fanfarr, Oban)
       )},
      # Start a worker by calling: Fanfarr.Worker.start_link(arg)
      # {Fanfarr.Worker, arg},
      # Start to serve requests, typically the last entry
      {DNSCluster, query: Application.get_env(:fanfarr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fanfarr.PubSub},
      FanfarrWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fanfarr.Supervisor]
    Supervisor.start_link(children, opts)
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
