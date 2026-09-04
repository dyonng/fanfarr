defmodule Fanfarr.Repo.Migrator do
  @moduledoc """
  Runs pending migrations at boot, on a single connection.

  `Ecto.Migrator`'s own child spec cannot be used here. It calls
  `Ecto.Migrator.with_repo/3` with no options, so when the repo is already
  started -- which it is, boot order being repo first -- the migrations run on
  the *running* pool. In production that is ten connections, and SQLite is the
  one supported database where that matters: each connection parses the schema
  for itself, and a connection that has not seen an `ALTER TABLE` still
  believes the old shape.

  So a migration that alters a table and a later one that depends on the
  alteration land on different connections and the second fails, on a fresh
  database, at boot, with `no such column`. It is a landmine rather than a
  constant failure: it needs two migrations in one run touching one table, so
  it stays hidden until the day it takes the container down. It did, on
  v0.1.39.

  Running with `pool_size: 1` removes the possibility. Migrations are strictly
  sequential anyway, so there is nothing to lose by it. This has to start
  *before* the repo, so `with_repo/3` starts a temporary instance of its own
  with that pool size, migrates, and stops it; the application's real repo then
  starts with its ordinary pool.
  """

  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    unless Keyword.get(opts, :skip, false) do
      for repo <- Keyword.fetch!(opts, :repos) do
        {:ok, _result, _apps} =
          Ecto.Migrator.with_repo(
            repo,
            &Ecto.Migrator.run(&1, :up, all: true),
            pool_size: 1
          )
      end
    end

    :ignore
  end
end
