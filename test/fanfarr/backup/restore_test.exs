defmodule Fanfarr.Backup.RestoreTest do
  @moduledoc """
  Staging a restore, and the swap the next boot does.

  The swap renames the database file and deletes the log beside it, so every
  case here passes explicit paths and works in a temp directory. Running it
  against the database the suite is using would be a memorable way to lose the
  suite.

  The case that matters most is the one where the staged file turns out not to
  be a database: the boot has to carry on with what it already had, because a
  machine that will not start can only be fixed by hand.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Backup
  alias Fanfarr.Backup.Restore

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Fanfarr.Settings.put_setting!("backup_dir", dir)
    %{dir: dir}
  end

  defp junk(path, body \\ "SQLite format 3\0 pretending") do
    File.write!(path, body)
    path
  end

  defp markers do
    Fanfarr.Repo.all(Oban.Job)
    |> Enum.filter(&(&1.worker == "Fanfarr.Workers.Backup"))
  end

  describe "staging" do
    test "keeps the state it is about to replace, and records what is staged", %{dir: dir} do
      {:ok, snapshot} = Backup.snapshot(dir)
      name = Path.basename(snapshot)

      assert {:ok, pending} = Restore.stage(name, dir: Path.join(dir, "restore"))

      assert pending["source"] == name
      assert pending["version"] =~ ~r/\d+\.\d+\.\d+/
      # The undo button: a pre-restore snapshot of what is going away.
      assert pending["safety_snapshot"] =~ "pre-restore-"
      assert Enum.any?(Backup.list(dir), &(&1.kind == :pre_restore))
    end

    test "refuses a name it does not have", %{dir: dir} do
      assert {:error, :no_such_snapshot} = Restore.stage("nope.sqlite", dir: Path.join(dir, "r"))
    end

    test "refuses to stage something that is not a database", %{dir: dir} do
      # The name and the first sixteen bytes both look right -- a header check
      # alone would pass this. Validation goes further for exactly this reason:
      # it opens the file and asks SQLite whether its pages hold together.
      junk(Path.join(dir, "fanfarr-20260101-000000.sqlite"))

      assert {:error, _reason} =
               Restore.stage("fanfarr-20260101-000000.sqlite", dir: Path.join(dir, "restore"))
    end

    test "cancel clears the staging without touching anything else", %{dir: dir} do
      {:ok, snapshot} = Backup.snapshot(dir)
      staging = Path.join(dir, "restore")
      {:ok, _pending} = Restore.stage(Path.basename(snapshot), dir: staging)

      assert Restore.cancel(staging) == :ok
      assert Restore.pending(staging) == nil
      refute File.exists?(Path.join(staging, "pending.sqlite"))
      # The snapshot it would have restored from is still there.
      assert File.exists?(snapshot)
    end
  end

  describe "staging an uploaded file" do
    test "a real database is staged, with the undo snapshot taken first", %{dir: dir} do
      {:ok, snapshot} = Backup.snapshot(dir)
      upload = Path.join(dir, "from-elsewhere.sqlite")
      File.cp!(snapshot, upload)
      staging = Path.join(dir, "staging")

      assert {:ok, pending} = Restore.stage_upload(upload, dir: staging, name: "an uploaded file")

      assert pending["source"] == "an uploaded file"
      assert pending["safety_snapshot"] =~ "pre-restore-"
      assert Restore.pending(staging) != nil
    end

    test "an uploaded file that is not a database is refused", %{dir: dir} do
      upload = junk(Path.join(dir, "not-a-db.sqlite"), "definitely not a database")
      staging = Path.join(dir, "staging")

      assert {:error, _reason} = Restore.stage_upload(upload, dir: staging)
      assert Restore.pending(staging) == nil
    end
  end

  describe "applying at boot" do
    test "swaps the files, keeps the one it replaced, and clears the log", %{dir: dir} do
      # A real snapshot, because validation opens the file and asks SQLite about
      # it -- a fake would be refused, which is the next test's subject.
      {:ok, snapshot} = Backup.snapshot(dir)
      staging = Path.join(dir, "restore")
      {:ok, _pending} = Restore.stage(Path.basename(snapshot), dir: staging)

      database = junk(Path.join(dir, "fanfarr.db"), "the database from before")
      # The log and shared memory of the database being replaced. These must not
      # survive into the new one.
      junk(Path.join(dir, "fanfarr.db-wal"), "stale log")
      junk(Path.join(dir, "fanfarr.db-shm"), "stale shm")

      assert Restore.apply_pending!(dir: staging, database: database) == :restored

      # The file in place is now the snapshot, and it is a real database.
      assert Backup.validate(database) == :ok
      refute File.exists?(Path.join(dir, "fanfarr.db-wal"))
      refute File.exists?(Path.join(dir, "fanfarr.db-shm"))
      refute File.exists?(Path.join(staging, "pending.sqlite"))
      assert Restore.pending(staging) == nil

      # What it replaced is kept, named for what it is.
      replaced = Path.wildcard(database <> ".replaced-*")
      assert [one] = replaced
      assert File.read!(one) == "the database from before"
    end

    test "a staged file that is not a database boots on what is already there", %{dir: dir} do
      staging = Path.join(dir, "restore")
      File.mkdir_p!(staging)
      junk(Path.join(staging, "pending.sqlite"), "definitely not a database")
      File.write!(Path.join(staging, "pending.json"), ~s({"source": "junk.sqlite"}))

      database = junk(Path.join(dir, "fanfarr.db"), "the database from before")

      assert {:error, :not_a_database} =
               Restore.apply_pending!(dir: staging, database: database)

      # Untouched, and the marker is gone so the next boot is ordinary.
      assert File.read!(database) == "the database from before"
      assert Path.wildcard(database <> ".replaced-*") == []
      assert Restore.pending(staging) == nil
      refute File.exists?(Path.join(staging, "pending.sqlite"))
    end

    test "a restore that cannot be copied into place leaves everything alone", %{dir: dir} do
      {:ok, snapshot} = Backup.snapshot(dir)
      staging = Path.join(dir, "restore")
      {:ok, _pending} = Restore.stage(Path.basename(snapshot), dir: staging)

      # A database whose directory does not exist: the copy into it fails. The
      # point is that this is an error rather than a crash -- a restore that
      # cannot be applied must still let the application start.
      missing = Path.join([dir, "no-such-dir", "fanfarr.db"])

      assert {:error, _reason} = Restore.apply_pending!(dir: staging, database: missing)
      assert Restore.pending(staging) == nil
      assert Path.wildcard(missing <> "*") == []
    end

    test "nothing staged is not an error", %{dir: dir} do
      assert Restore.apply_pending!(
               dir: Path.join(dir, "restore"),
               database: Path.join(dir, "db")
             ) ==
               :none
    end

    test "a marker without its file is ignored", %{dir: dir} do
      staging = Path.join(dir, "restore")
      File.mkdir_p!(staging)
      File.write!(Path.join(staging, "pending.json"), ~s({"source": "gone.sqlite"}))

      database = junk(Path.join(dir, "fanfarr.db"))

      assert Restore.apply_pending!(dir: staging, database: database) == :none
      assert File.read!(database) == "SQLite format 3\0 pretending"
    end
  end

  describe "the jobs left behind" do
    test "unfinished work is cancelled, because it belonged to the old database" do
      {:ok, _} = Fanfarr.Repo.insert(Fanfarr.Workers.Backup.new(%{trigger: "manual"}))
      {:ok, _} = Fanfarr.Repo.insert(Fanfarr.Workers.Scheduler.new(%{}))

      assert Restore.discard_unfinished_jobs() == 2

      states = Fanfarr.Repo.all(Oban.Job) |> Enum.map(& &1.state) |> Enum.uniq()
      assert states == ["cancelled"]
    end

    test "cleanup does nothing when this boot was not a restore" do
      {:ok, _} = Fanfarr.Repo.insert(Fanfarr.Workers.Backup.new(%{trigger: "manual"}))

      refute Restore.restored?()
      assert Restore.cleanup_after_restore() == :ok
      assert markers() |> Enum.map(& &1.state) == ["available"]
    end

    test "cleanup runs once, when this boot was a restore" do
      {:ok, _} = Fanfarr.Repo.insert(Fanfarr.Workers.Backup.new(%{trigger: "manual"}))
      Restore.mark_restored()

      assert Restore.cleanup_after_restore() == :ok
      assert markers() |> Enum.map(& &1.state) == ["cancelled"]

      # And the flag is cleared, so a later cleanup does not repeat it.
      refute Restore.restored?()
    end
  end
end
