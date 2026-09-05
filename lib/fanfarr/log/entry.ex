defmodule Fanfarr.Log.Entry do
  @moduledoc """
  A persisted log line.

  A plain Ecto schema rather than an Ash resource, for the same reason
  `Oban.Job` is one: nothing in the domain hangs off a log line, and the only
  writer is a batched `insert_all` on the logging path, where Ash's own query
  logging would be a liability rather than a feature. See `Fanfarr.Log.Store`.

  Timestamps are the logger's own `at`, not `inserted_at`: entries are written
  a second or so after they happen, and the time that matters is when the
  thing was logged.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "log_entries" do
    field :at, :utc_datetime_usec
    field :level, :string
    field :message, :string
    field :where, :string
  end
end
