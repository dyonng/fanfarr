defmodule Fanfarr.Repo.Migrations.CreateLogEntries do
  @moduledoc """
  Somewhere for the log to survive a restart.

  Hand-written rather than generated: this is not an Ash resource. Nothing in
  the domain hangs off a log line, every write is a batched `insert_all` on
  the logging path, and going through Ash there would mean the framework's own
  query logging on the one code path that must not log. See
  `Fanfarr.Log.Store`.

  No index beyond the primary key. Every read is "the newest N, filtered",
  which walks the id index backwards, and the table is capped in the
  thousands -- an index on `level` would cost every insert to save nothing
  measurable.
  """

  use Ecto.Migration

  def up do
    create table(:log_entries) do
      add :at, :utc_datetime_usec, null: false
      add :level, :text, null: false
      add :message, :text, null: false
      add :where, :text
    end
  end

  def down do
    drop table(:log_entries)
  end
end
