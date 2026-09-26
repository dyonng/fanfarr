defmodule Fanfarr.Backup.Restore do
  @moduledoc """
  Putting a snapshot back.

  ## Why the swap does not happen while the application is running

  SQLite keeps a write-ahead log beside the database, at a fixed path. Replacing
  the database under a running application leaves the *old* database's log next
  to the *new* file, and SQLite will try to apply one database's log to
  another, which is the one way to turn "restore a backup" into "lose both".

  So nothing is swapped while the app is up. A restore is staged -- the chosen
  snapshot is validated, copied into a pending directory, and recorded in a
  marker -- and then the application restarts. The swap is the first thing the
  next boot does, before the repo or anything else that opens the file.

  ## The failure mode is the safe one

  A staged file that cannot be validated is set aside, its marker is cleared,
  and the boot carries on with the database that is already there. A bad
  restore is a non-event rather than a machine that will not start, which
  matters because the only way to fix a machine that will not start is to go
  back to the files by hand.

  ## What is kept

  The database being replaced is renamed, not deleted: `fanfarr.db.replaced-
  <timestamp>`. A restore that was a mistake is therefore itself undoable, and
  that copy is the one an operator will want. The `-wal` and `-shm` files are
  deleted rather than moved, because they belong to the database being replaced
  and must not survive into the new one.
  """

  require Logger

  @pending "pending.sqlite"
  @marker "pending.json"
  @unfinished ~w(available scheduled executing retryable)
  @flag {__MODULE__, :restored}

  @doc """
  Where a staged restore waits between the restart and the next boot.

  Beside the database, deliberately: applying a restore renames the staged file
  over the database, and a rename across filesystems fails with `EXDEV` -- so
  this has to be on the same volume as the thing it will replace. The override
  is an application environment rather than a setting, because a user pointing
  this at another disk would be pointing it at a bug.
  """
  @spec dir() :: String.t()
  def dir do
    Application.get_env(:fanfarr, :restore_staging_dir) ||
      Path.join(Path.dirname(Fanfarr.Backup.database_path()), "restore")
  end

  @doc """
  Stages restoring from a snapshot that is already on disk.

  A `pre-restore` snapshot is taken first, so the state about to be replaced is
  kept and named for what it is. Returns the staged marker, which is what the
  settings page shows while the restart is pending.
  """
  @spec stage(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage(name, opts \\ []) do
    directory = Keyword.get(opts, :dir, dir())

    with %{path: source} <- Enum.find(Fanfarr.Backup.list(), &(&1.name == name)),
         :ok <- Fanfarr.Backup.validate(source),
         {:ok, safety} <- Fanfarr.Backup.pre_restore(),
         :ok <- File.mkdir_p(directory),
         :ok <- File.cp(source, Path.join(directory, @pending)),
         :ok <- write_marker(directory, name, safety) do
      Logger.warning("[fanfarr] a restore of #{name} is staged; it applies on the next start")

      {:ok, pending(directory)}
    else
      nil -> {:error, :no_such_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stages a restore from a file the operator uploaded.

  The recovery path that matters most: when the disk holding the snapshots is
  the thing that failed, there is no snapshot left to choose from, and the copy
  kept somewhere else is the only one that exists.

  Uploaded bytes are treated as untrusted. The name is not used as a path, the
  content is validated like any other candidate, and nothing is staged unless it
  passes -- the one thing worse than losing a database is replacing it with a
  file that is not one.
  """
  @spec stage_upload(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage_upload(source, opts \\ []) do
    directory = Keyword.get(opts, :dir, dir())
    label = Keyword.get(opts, :name, "an uploaded file")

    with :ok <- Fanfarr.Backup.validate(source),
         {:ok, safety} <- Fanfarr.Backup.pre_restore(),
         :ok <- File.mkdir_p(directory),
         :ok <- File.cp(source, Path.join(directory, @pending)),
         :ok <- write_marker(directory, label, safety) do
      Logger.warning("[fanfarr] a restore from #{label} is staged; it applies on the next start")

      {:ok, pending(directory)}
    end
  end

  @doc "The staged restore, for the settings page to show, or nil."
  @spec pending(String.t()) :: map() | nil
  def pending(directory \\ dir()) do
    case File.read(Path.join(directory, @marker)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Abandons a staged restore without restarting."
  @spec cancel(String.t()) :: :ok
  def cancel(directory \\ dir()) do
    remove(Path.join(directory, @marker))
    remove(Path.join(directory, @pending))
    :ok
  end

  @doc """
  Applies a staged restore. The first thing a boot does.

  Paths are arguments so a test can exercise a swap without touching the
  database the suite is running on.
  """
  @spec apply_pending!(keyword()) :: :restored | :none | {:error, term()}
  def apply_pending!(opts \\ []) do
    directory = Keyword.get(opts, :dir, dir())
    database = Keyword.get(opts, :database, Fanfarr.Backup.database_path())
    staged = Path.join(directory, @pending)
    marker = Path.join(directory, @marker)

    if File.regular?(marker) and File.regular?(staged) do
      apply_staged(database, staged, marker)
    else
      :none
    end
  end

  defp apply_staged(database, staged, marker) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    incoming = database <> ".incoming-" <> stamp
    replaced = database <> ".replaced-" <> stamp

    with :ok <- Fanfarr.Backup.validate(staged),
         # Copied into the database's own directory before anything moves, so
         # the swap that follows is a rename within one filesystem -- the only
         # kind that is atomic, and the only kind that cannot half-happen.
         :ok <- copy(staged, incoming),
         :ok <- move_apart(database, replaced),
         :ok <- clear_log(database),
         :ok <- swap_in(incoming, database, replaced) do
      remove(marker)
      remove(staged)

      Logger.warning(
        "[fanfarr] restored the database from a staged backup; " <>
          "the file it replaced is #{Path.basename(replaced)}"
      )

      :restored
    else
      {:error, reason} ->
        # Nothing is left half-done: the incoming copy, the marker and the
        # staged file all go, and the boot continues on the database that is
        # already there. Refusing to start would be the one outcome this whole
        # design exists to avoid.
        Logger.error(
          "[fanfarr] the staged restore cannot be applied (#{inspect(reason, limit: 3)}); " <>
            "keeping the current database"
        )

        remove(incoming)
        remove(marker)
        remove(staged)
        {:error, reason}
    end
  end

  defp copy(source, target) do
    case File.cp(source, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:copy, reason}}
    end
  end

  # A missing database is not a failure here: a first boot has nothing to move,
  # and the staged file is the whole of what will exist.
  defp move_apart(database, replaced) do
    case File.rename(database, replaced) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:move, reason}}
    end
  end

  # Deleted, not moved: these belong to the database being replaced, and left
  # behind SQLite would apply them to the file that just arrived.
  defp clear_log(database) do
    remove(database <> "-wal")
    remove(database <> "-shm")
    :ok
  end

  defp swap_in(incoming, database, replaced) do
    case File.rename(incoming, database) do
      :ok ->
        :ok

      {:error, reason} ->
        # Put back what was moved aside. The database path must never be left
        # empty, or the next thing to open it creates a blank database -- and a
        # restore that failed would then have cost the data it was meant to keep.
        case File.rename(replaced, database) do
          :ok ->
            :ok

          {:error, restore_reason} ->
            Logger.error(
              "[fanfarr] could not put the original database back " <>
                "(#{inspect(restore_reason)}); it is at #{replaced}"
            )
        end

        {:error, {:swap, reason}}
    end
  end

  defp write_marker(directory, name, safety) do
    body = %{
      "source" => name,
      "staged_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "safety_snapshot" => Path.basename(safety),
      "version" => Fanfarr.Version.display()
    }

    File.write(Path.join(directory, @marker), Jason.encode!(body))
  end

  @doc "Records that this boot came out of a restore, for the cleanup below."
  @spec mark_restored() :: :ok
  def mark_restored, do: :persistent_term.put(@flag, true)

  @doc "Whether this boot came out of a restore."
  @spec restored?() :: boolean()
  def restored?, do: :persistent_term.get(@flag, false)

  @doc """
  Drops jobs that were queued against the database that has just been replaced.

  They name rows that may no longer exist, and Oban would otherwise rescue the
  ones that were mid-flight -- two hours later, by its own lifeline -- and run
  them against data they were never about.
  """
  @spec discard_unfinished_jobs() :: non_neg_integer()
  def discard_unfinished_jobs do
    import Ecto.Query, only: [from: 2]

    {count, _} =
      Fanfarr.Repo.update_all(
        from(j in Oban.Job, where: j.state in ^@unfinished),
        set: [state: "cancelled", cancelled_at: DateTime.utc_now()]
      )

    if count > 0 do
      Logger.warning(
        "[fanfarr] cancelled #{count} job(s) that belonged to the database before the restore"
      )
    end

    count
  end

  @doc "Runs once, after the tree is up, if this boot came from a restore."
  @spec cleanup_after_restore() :: :ok
  def cleanup_after_restore do
    if restored?() do
      discard_unfinished_jobs()
      :persistent_term.erase(@flag)
    end

    :ok
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("[fanfarr] could not remove #{path}: #{inspect(reason)}")
    end
  end
end
