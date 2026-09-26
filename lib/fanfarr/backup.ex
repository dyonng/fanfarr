defmodule Fanfarr.Backup do
  @moduledoc """
  Snapshots of the SQLite file, taken while the application is running.

  The database is the whole of this application's state: the settings, the
  mirror of what Plex holds, the ThemerrDB cache, and the append-only record of
  every theme written. Nothing else on disk needs keeping and nothing else can
  reconstruct it -- Plex cannot be asked what Fanfarr did, and an uploaded theme
  cannot be read back out.

  ## What this module refuses to do

  A backup system can fail in two directions and the quiet one is worse: taking
  nothing while reporting success. Three rules in here exist to prevent that.

    * **A snapshot is verified before it is announced.** `VACUUM INTO` returning
      `:ok` is not evidence that the file is a database -- a volume that fills
      up mid-write can leave a partial file, and the size alone will look
      plausible. Every snapshot is reopened and checked, and deleted if it does
      not pass, so the log line and the listing only ever describe something
      that can be restored.

    * **Only files this module wrote are ever deleted.** Pruning works from the
      name, never from what happens to be in the directory. A database an
      operator copied in by hand is theirs, and it is the one they would most
      want back.

    * **Every failure is logged.** The first version returned an error the
      caller discarded, so a snapshot that could not be written -- an
      unwritable directory, a full disk -- reported nothing at all, and backups
      looked healthy while taking none.

  `VACUUM INTO` is what makes any of this possible without stopping the
  application: it writes a consistent, compacted copy through SQLite's own
  reader, so it is safe while other connections are writing, and it needs no
  `sqlite3` binary -- which the image deliberately does not install.

  It runs on a connection of its own rather than through `Fanfarr.Repo`, because
  `VACUUM` is illegal inside a transaction and every test runs inside one.

  Restoring is not done from this module; `docs/deployment.md` has the manual
  procedure, and the in-app restore is a separate step.
  """

  require Logger

  @default_keep 7
  @default_interval_hours 24
  # Pre-restore snapshots are the undo button for a restore, so they outlive a
  # rotation -- but not forever, or a habit of restoring would fill the volume.
  @pre_restore_keep 2

  @auto_prefix "fanfarr-"
  @pre_restore_prefix "pre-restore-"
  @extension ".sqlite"
  @name_attempts 100

  # A snapshot is not larger than the database it copies, but it is not much
  # smaller either, and a copy that runs out of room halfway is the worst
  # outcome available: it looks like a file and cannot be restored from.
  @headroom_bytes 8 * 1024 * 1024

  @type kind :: :auto | :pre_restore | :foreign

  @type snapshot :: %{
          path: String.t(),
          name: String.t(),
          bytes: non_neg_integer() | nil,
          taken_at: DateTime.t() | nil,
          kind: kind(),
          metadata: map() | nil
        }

  @doc """
  Where snapshots are written.

  `backup_dir` if the operator set one -- the point of which is to put the
  copies on a different disk from the thing they copy -- and otherwise a
  `backups` directory beside the database, inside the config volume.
  """
  @spec dir() :: String.t()
  def dir do
    case Fanfarr.Config.get("backup_dir") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default_dir()
          path -> Path.expand(path)
        end

      _ ->
        default_dir()
    end
  end

  defp default_dir, do: Path.join(Path.dirname(database_path()), "backups")

  @doc """
  Whether backups run unattended. On unless turned off, like the crop switch:
  a snapshot costs a few megabytes, and not having one costs the record of
  everything the appliance has done.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Fanfarr.Config.get("backup_enabled") not in ["false", "0", "off"]

  @doc """
  Hours between automatic snapshots, or nil when they are off.

  `0` means off, the same as every other interval in this application. The
  switch above is the primary control; this is the second way to say the same
  thing, and it has to mean it rather than quietly becoming the default.
  """
  @spec interval_hours() :: pos_integer() | nil
  def interval_hours do
    case Fanfarr.Config.get("backup_interval_hours") do
      nil -> @default_interval_hours
      value when is_binary(value) -> interval_from(value)
      _ -> @default_interval_hours
    end
  end

  @doc "How many automatic snapshots to keep. Older ones are deleted after a successful write."
  @spec keep() :: pos_integer()
  def keep do
    case Fanfarr.Config.get("backup_keep") do
      nil -> @default_keep
      value when is_binary(value) -> positive(value, @default_keep)
      _ -> @default_keep
    end
  end

  # 0 is a deliberate "off" for the interval, the same as every other interval
  # in this application. Anything unparseable falls back instead of failing: a
  # typo in a setting must not stop the backups.
  defp interval_from(value) do
    case String.trim(value) do
      "0" -> nil
      trimmed -> positive(trimmed, @default_interval_hours)
    end
  end

  # One parser with the caller's default, because the two settings do not share
  # one: falling back to 24 for a mistyped `keep` was a real bug, and the sort
  # of thing a single shared helper invites.
  defp positive(value, default) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @doc """
  Existing snapshots, newest first, with whatever metadata was written beside
  them.

  Ordered by name rather than modification time: the name carries the
  timestamp, so it sorts correctly even when several land in the same second.
  Nothing here raises -- a file that cannot be read is listed as unreadable
  rather than taking down the caller, which in one case is the scheduler.
  """
  @spec list(String.t()) :: [snapshot()]
  def list(directory \\ dir()) do
    directory
    |> Path.join("*#{@extension}")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.map(&info/1)
  end

  @doc "The newest snapshot, or nil when there are none."
  @spec newest(String.t()) :: snapshot() | nil
  def newest(directory \\ dir()), do: List.first(list(directory))

  @doc "Totals for the settings page: how many, how much room, and the newest."
  @spec usage(String.t()) :: %{
          count: non_neg_integer(),
          bytes: non_neg_integer(),
          newest: snapshot() | nil
        }
  def usage(directory \\ dir()) do
    snapshots = list(directory)

    %{
      count: length(snapshots),
      bytes: snapshots |> Enum.map(&(&1.bytes || 0)) |> Enum.sum(),
      newest: List.first(snapshots)
    }
  end

  @doc """
  Whether a snapshot is due: none taken yet, or the newest is older than the
  interval.

  A snapshot that cannot be stat'd counts as due. Reading "I cannot tell how
  old this is" as "fresh" is how a backup system stops working and never
  mentions it.
  """
  @spec due?(String.t()) :: boolean()
  def due?(directory \\ dir()) do
    with true <- enabled?(),
         hours when is_integer(hours) <- interval_hours() do
      case newest_auto(directory) do
        nil -> true
        snapshot -> stale?(snapshot, hours)
      end
    else
      _ -> false
    end
  end

  defp newest_auto(directory) do
    directory |> list() |> Enum.find(&(&1.kind == :auto))
  end

  # The name carries when the snapshot was taken, and that is what the interval
  # is measured from -- not the modification time, which is whatever a copy or a
  # restore last did to it. The mtime is a fallback only for a name that cannot
  # be read, which our own names always can be.
  defp stale?(snapshot, hours) do
    case snapshot_time(snapshot) do
      {:ok, at} -> DateTime.diff(DateTime.utc_now(), at, :hour) >= hours
      :error -> true
    end
  end

  defp snapshot_time(%{taken_at: %DateTime{} = at}), do: {:ok, at}

  defp snapshot_time(snapshot) do
    case File.stat(snapshot.path, time: :posix) do
      {:ok, %{mtime: mtime}} -> {:ok, DateTime.from_unix!(mtime)}
      _ -> :error
    end
  end

  @doc """
  Writes a snapshot and prunes the old ones.

  The copy is written and verified before anything is deleted, so a failure can
  never cost snapshots that already exist. A file that fails verification is
  removed rather than left behind, because a partial database in the directory
  is worse than an empty one: it is listed as a backup.
  """
  @spec snapshot(String.t()) :: {:ok, String.t()} | {:error, term()}
  def snapshot(directory \\ dir()) do
    with :ok <- File.mkdir_p(directory),
         :ok <- preflight(directory),
         {:ok, path} <- unique_path(directory) do
      case write_and_verify(path) do
        :ok ->
          write_metadata(path)
          log_written(path)
          prune(directory, keep(), exclude: path)
          {:ok, path}

        {:error, reason} ->
          remove(path)
          Logger.error("[fanfarr] database backup failed: #{describe(reason)} (at #{directory})")
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("[fanfarr] database backup failed: #{describe(reason)} (at #{directory})")
        {:error, reason}
    end
  end

  @doc """
  Whether a file is a database this application could restore from.

  Checks the SQLite header, asks SQLite to verify its own page structure, and
  confirms the schema is in there. Deliberately `quick_check` rather than
  `integrity_check`: the latter cross-checks every index against every table and
  costs a full read, which is the cost of the copy itself. A file that passes
  this and is still broken is not a failure mode SQLite warns about.

  Used on every snapshot, and by the restore path on a file it did not write.
  """
  @spec validate(Path.t()) :: :ok | {:error, term()}
  def validate(path) do
    with :ok <- header(path),
         {:ok, db} <- Exqlite.Sqlite3.open(path) do
      try do
        with :ok <- check(db, "pragma quick_check", "ok") do
          # The count comes back as an integer, not a string. Comparing it to
          # "1" rejected every valid snapshot -- a fine way to prove the
          # verification really runs, and a terrible way to ship it.
          check(db, "select count(*) from sqlite_master where name = 'library_media_items'", 1)
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes managed snapshots beyond the newest `keep`, and pre-restore snapshots
  beyond their own smaller cap.

  Only files this module wrote are touched. Returns what was deleted and what
  could not be, because a snapshot that cannot be removed accumulates forever
  and is worth a log line rather than silence.
  """
  @spec prune(String.t(), pos_integer(), keyword()) :: %{
          deleted: non_neg_integer(),
          failed: non_neg_integer()
        }
  def prune(directory \\ dir(), keep \\ keep(), opts \\ []) do
    exclude = Keyword.get(opts, :exclude)
    snapshots = list(directory)

    doomed =
      snapshots
      |> Enum.filter(&(&1.kind == :auto and &1.path != exclude))
      |> Enum.drop(keep)
      |> Enum.concat(
        Enum.drop(Enum.filter(snapshots, &(&1.kind == :pre_restore)), @pre_restore_keep)
      )

    Enum.reduce(doomed, %{deleted: 0, failed: 0}, fn snapshot, acc ->
      case remove(snapshot.path) do
        :ok ->
          %{acc | deleted: acc.deleted + 1}

        {:error, reason} ->
          Logger.warning(
            "[fanfarr] could not delete the old backup #{snapshot.name}: #{describe(reason)}"
          )

          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  @doc "Deletes one snapshot and the metadata beside it."
  @spec remove(Path.t()) :: :ok | {:error, term()}
  def remove(path) do
    File.rm(path <> ".json")

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  A snapshot's path from its metadata sidecar, if it has one.

  Written at snapshot time and used to tell the operator which application
  version a file came from, which matters when deciding whether a snapshot is
  safe to restore.
  """
  @spec metadata(Path.t()) :: map() | nil
  def metadata(path) do
    with {:ok, body} <- File.read(path <> ".json"),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      decoded
    else
      _ -> nil
    end
  end

  # Writability first, because that is the failure that actually happened: a
  # directory owned by somebody else produced no snapshot, no error and no log.
  defp preflight(directory) do
    with :ok <- writable(directory) do
      need = database_bytes() + @headroom_bytes

      case Fanfarr.Library.DiskSpace.free_bytes(directory) do
        nil ->
          :ok

        free when free >= need ->
          :ok

        free ->
          {:error, {:no_space, need, free}}
      end
    end
  end

  defp writable(directory) do
    # Deliberately the same probe name `Fanfarr.Health` uses: two names for one
    # question is how the health check and the snapshot came to disagree about
    # whether a directory was writable.
    probe = Path.join(directory, ".fanfarr-write-check")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, {:directory_not_writable, reason}}
    end
  end

  defp write_and_verify(path) do
    with :ok <- write_snapshot(path) do
      validate(path)
    end
  end

  # A connection of its own, and no transaction: VACUUM refuses to run inside
  # one. That is also the point -- SQLite takes a consistent read of a database
  # other connections are writing to, which is what makes a live copy safe.
  defp write_snapshot(path) do
    escaped = String.replace(path, "'", "''")

    case Exqlite.Sqlite3.open(database_path()) do
      {:ok, db} ->
        try do
          case Exqlite.Sqlite3.execute(db, "VACUUM INTO '#{escaped}'") do
            :ok -> :ok
            {:error, reason} -> {:error, {:vacuum, reason}}
          end
        after
          Exqlite.Sqlite3.close(db)
        end

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  defp check(db, sql, expected) do
    with {:ok, statement} <- Exqlite.Sqlite3.prepare(db, sql) do
      try do
        case Exqlite.Sqlite3.step(db, statement) do
          {:row, [^expected]} -> :ok
          {:row, [other]} -> {:error, {:unexpected, sql, other}}
          :done -> {:error, {:empty, sql}}
          {:error, reason} -> {:error, reason}
        end
      after
        Exqlite.Sqlite3.release(db, statement)
      end
    end
  end

  defp header(path) do
    case File.read(path) do
      {:ok, <<"SQLite format 3", 0, _rest::binary>>} -> :ok
      {:ok, _other} -> {:error, :not_a_database}
      {:error, reason} -> {:error, reason}
    end
  end

  # Two snapshots in the same second are a button pressed twice, not a mistake
  # worth failing over -- but the attempt has to end somewhere, and returning a
  # name that already exists would make VACUUM fail with a confusing error.
  defp unique_path(directory) do
    base = Path.join(directory, @auto_prefix <> stamp())

    case Enum.find(1..@name_attempts, fn n -> not File.exists?(name_for(base, n)) end) do
      nil -> {:error, :too_many_snapshots}
      n -> {:ok, name_for(base, n)}
    end
  end

  defp name_for(base, 1), do: base <> @extension
  defp name_for(base, n), do: "#{base}-#{n}#{@extension}"

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")

  defp write_metadata(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        body =
          Jason.encode!(%{
            "version" => Fanfarr.Version.display(),
            "taken_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "bytes" => size
          })

        File.write(path <> ".json", body)

      _ ->
        :ok
    end
  end

  defp log_written(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        Logger.info("[fanfarr] wrote a database backup: #{Path.basename(path)} (#{size} bytes)")

      _ ->
        Logger.info("[fanfarr] wrote a database backup: #{Path.basename(path)}")
    end
  end

  defp info(path) do
    # `time: :posix` matters: without it `mtime` is an Erlang datetime tuple,
    # and the fallback for a name that cannot be parsed -- a file an operator
    # copied in -- crashed on it instead of listing it.
    case File.stat(path, time: :posix) do
      {:ok, %{size: size, mtime: mtime}} ->
        %{
          path: path,
          name: Path.basename(path),
          bytes: size,
          taken_at: taken_at(Path.basename(path)) || from_posix(mtime),
          kind: kind(Path.basename(path)),
          metadata: metadata(path)
        }

      _ ->
        %{
          path: path,
          name: Path.basename(path),
          bytes: nil,
          taken_at: taken_at(Path.basename(path)),
          kind: kind(Path.basename(path)),
          metadata: nil
        }
    end
  end

  @doc """
  Whether this application wrote the file, and which sort it is.

  Anything else is somebody else's file: listed, shown, restorable, and never
  deleted or counted against the rotation.
  """
  @spec kind(String.t()) :: kind()
  def kind(name) do
    cond do
      String.starts_with?(name, @auto_prefix) -> :auto
      String.starts_with?(name, @pre_restore_prefix) -> :pre_restore
      true -> :foreign
    end
  end

  defp taken_at(name) do
    case Regex.run(~r/(\d{8})-(\d{6})/, name) do
      [_, date, time] -> parse_stamp(date, time)
      _ -> nil
    end
  end

  defp parse_stamp(date, time) do
    with {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(String.slice(date, 0, 4)),
             String.to_integer(String.slice(date, 4, 2)),
             String.to_integer(String.slice(date, 6, 2)),
             String.to_integer(String.slice(time, 0, 2)),
             String.to_integer(String.slice(time, 2, 2)),
             String.to_integer(String.slice(time, 4, 2))
           ),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      datetime
    else
      _ -> nil
    end
  end

  defp from_posix(mtime), do: DateTime.from_unix!(mtime)

  defp database_bytes do
    case File.stat(database_path()) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp describe(:not_a_database), do: "the copy is not a SQLite database"
  defp describe(:too_many_snapshots), do: "too many snapshots in the same second"
  defp describe(reason) when is_binary(reason), do: reason

  defp describe({:no_space, need, free}) do
    "not enough room for #{need} bytes (#{free} free)"
  end

  defp describe({:directory_not_writable, reason}) do
    "the backup directory is not writable (#{describe(reason)})"
  end

  defp describe({:vacuum, reason}), do: "SQLite refused the copy (#{describe(reason)})"
  defp describe({:open, reason}), do: "could not open the database (#{describe(reason)})"
  defp describe({:unexpected, sql, other}), do: "#{sql} answered #{inspect(other)}"
  defp describe({:empty, sql}), do: "#{sql} returned nothing"
  defp describe({:error, reason}), do: describe(reason)
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(other), do: inspect(other)

  # The path `config/runtime.exs` resolved, read back rather than recomputed:
  # DATABASE_PATH can point anywhere, and a backup beside the database is the
  # one place certain to be on the same volume as the thing it copies.
  defp database_path do
    :fanfarr
    |> Application.get_env(Fanfarr.Repo, [])
    |> Keyword.get(:database)
    |> case do
      path when is_binary(path) ->
        if String.contains?(path, "/"), do: path, else: fallback_database_path()

      _ ->
        fallback_database_path()
    end
  end

  # An in-memory or otherwise unplaceable database has no directory to sit
  # beside, so the config volume is used rather than the working directory.
  defp fallback_database_path do
    Path.join(System.get_env("FANFARR_CONFIG_DIR", "/config"), "fanfarr.db")
  end
end
