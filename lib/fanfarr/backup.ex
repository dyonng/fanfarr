defmodule Fanfarr.Backup do
  @moduledoc """
  Snapshots of the SQLite file, taken while the application is running.

  The database is the whole of this application's state: the settings, the
  mirror of what Plex holds, the ThemerrDB cache, and the append-only record of
  every theme written. Nothing else on disk needs keeping and nothing else can
  reconstruct it -- Plex cannot be asked what Fanfarr did, and an uploaded theme
  cannot be read back out. It was the one file worth copying, and there was no
  copy of it anywhere.

  `VACUUM INTO` is what makes this possible without stopping anything. It
  writes a consistent, compacted copy through SQLite's own reader, so it is safe
  while other connections are writing, and it needs no `sqlite3` binary -- which
  the image deliberately does not install.

  It runs on a connection of its own rather than through `Fanfarr.Repo`, for
  two reasons. `VACUUM` is illegal inside a transaction, and every test runs
  inside one; and a compaction reads the whole database, which is not work to
  hold a pool connection for.

  Restoring is deliberately manual and lives in `docs/deployment.md`. Swapping
  a database underneath a running application is not something to automate from
  inside that application.
  """

  require Logger

  @default_keep 7
  @default_interval_hours 24

  @doc "Where snapshots are written: beside the database, inside the /config volume."
  @spec dir() :: String.t()
  def dir, do: Path.join(Path.dirname(database_path()), "backups")

  @doc """
  Whether backups run unattended. On unless turned off, like the crop switch:
  the cost of a snapshot is a few megabytes and the cost of not having one is
  the record of everything the appliance has done.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Fanfarr.Config.get("backup_enabled") not in ["false", "0", "off"]

  @doc "How many snapshots to keep. Older ones are deleted after a successful write."
  @spec keep() :: pos_integer()
  def keep, do: positive_setting("backup_keep", @default_keep)

  @doc "Hours between automatic snapshots."
  @spec interval_hours() :: pos_integer()
  def interval_hours, do: positive_setting("backup_interval_hours", @default_interval_hours)

  @doc """
  Existing snapshots, newest first.

  Ordered by name rather than mtime: the name carries the timestamp, so it
  sorts correctly even when several snapshots land in the same second, which
  they do in tests and would if someone pressed a button twice.
  """
  @spec list(String.t()) :: [
          %{path: String.t(), name: String.t(), bytes: non_neg_integer(), taken_at: String.t()}
        ]
  def list(directory \\ dir()) do
    directory
    |> Path.join("*.sqlite")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.map(fn path ->
      %{
        path: path,
        name: Path.basename(path),
        bytes: File.stat!(path).size,
        taken_at: taken_at(Path.basename(path))
      }
    end)
  end

  @doc "The newest snapshot, or nil when there are none."
  @spec newest(String.t()) :: map() | nil
  def newest(directory \\ dir()), do: List.first(list(directory))

  @doc """
  Whether a snapshot is due: none yet, or the newest is older than the interval.
  """
  @spec due?(String.t()) :: boolean()
  def due?(directory \\ dir()) do
    enabled?() and
      case newest(directory) do
        nil -> true
        snapshot -> age_hours(snapshot) >= interval_hours()
      end
  end

  @doc """
  Takes a snapshot if one is due. Called on the scheduler heartbeat, so a
  disabled switch costs a directory listing every five minutes and nothing else.
  """
  @spec run_if_due(String.t()) :: :ok | {:ok, String.t()} | {:error, term()}
  def run_if_due(directory \\ dir()) do
    if due?(directory), do: snapshot(directory), else: :ok
  end

  @doc """
  Writes a snapshot and prunes the old ones.

  The copy is written first and the pruning happens after, so a failure to
  write never deletes the snapshots that already exist.
  """
  @spec snapshot(String.t()) :: {:ok, String.t()} | {:error, term()}
  def snapshot(directory \\ dir()) do
    with :ok <- File.mkdir_p(directory),
         path = unique_path(directory),
         :ok <- write_snapshot(path) do
      Logger.info(
        "[fanfarr] wrote a database backup: #{Path.basename(path)} " <>
          "(#{File.stat!(path).size} bytes)"
      )

      prune(directory)
      {:ok, path}
    end
  end

  @doc "Deletes all but the newest `keep` snapshots. Returns how many went."
  @spec prune(String.t(), pos_integer()) :: non_neg_integer()
  def prune(directory \\ dir(), keep \\ keep()) do
    directory
    |> list()
    |> Enum.drop(keep)
    |> Enum.reduce(0, fn snapshot, deleted ->
      case File.rm(snapshot.path) do
        :ok -> deleted + 1
        {:error, _} -> deleted
      end
    end)
  end

  # A separate connection, and no transaction: `VACUUM` refuses to run inside
  # one. Somewhere else in this application the argument would be that the copy
  # could catch a half-written page; here it is the opposite -- SQLite's
  # VACUUM INTO takes its own consistent read, which is exactly why this is the
  # supported way to copy a live database.
  defp write_snapshot(path) do
    escaped = String.replace(path, "'", "''")

    case Exqlite.Sqlite3.open(database_path()) do
      {:ok, db} ->
        try do
          case Exqlite.Sqlite3.execute(db, "VACUUM INTO '#{escaped}'") do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        after
          Exqlite.Sqlite3.close(db)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Two snapshots in one second are a button pressed twice, not a mistake worth
  # failing over.
  defp unique_path(directory) do
    base =
      Path.join(directory, "fanfarr-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}")

    Enum.reduce_while(1..99, base <> ".sqlite", fn n, candidate ->
      if File.exists?(candidate), do: {:cont, "#{base}-#{n}.sqlite"}, else: {:halt, candidate}
    end)
  end

  defp taken_at(name) do
    case Regex.run(~r/fanfarr-(\d{8})-(\d{6})/, name) do
      [_, date, time] -> "#{date} #{time}"
      _ -> name
    end
  end

  defp age_hours(snapshot) do
    case File.stat(snapshot.path, time: :posix) do
      {:ok, %{mtime: mtime}} -> (System.os_time(:second) - mtime) / 3600
      _ -> 0.0
    end
  end

  defp positive_setting(key, default) do
    case Fanfarr.Config.get(key) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, ""} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  # The same path `config/runtime.exs` resolved, read back rather than
  # recomputed: DATABASE_PATH can point anywhere, and a backup beside the
  # database is the one place it is certain to be on the same volume as the
  # thing it copies.
  defp database_path do
    :fanfarr
    |> Application.get_env(Fanfarr.Repo, [])
    |> Keyword.get(:database)
    |> case do
      path when is_binary(path) ->
        path

      _ ->
        Path.join(System.get_env("FANFARR_CONFIG_DIR", "/config"), "fanfarr.db")
    end
  end
end
