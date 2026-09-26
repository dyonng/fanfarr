defmodule Fanfarr.BackupTest do
  @moduledoc """
  Snapshots of the live database.

  The rows a test writes are invisible to a snapshot, and that is correct
  rather than a limitation being worked around: every test runs inside the
  sandbox transaction, and a second connection -- which is what a backup is --
  cannot see uncommitted work by design. So what is asserted here is that the
  copy is a real, whole, openable database with the schema in it, plus the
  rules that keep the feature from lying about what it did.

  Three of these are regression tests for bugs that shipped in the first
  version of this module: pruning files it did not write, an interval of 0
  quietly meaning 24 hours, and a failure nobody was told about.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Backup
  alias Fanfarr.Workers.Backup, as: BackupWorker

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-backup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, name, body \\ "not a database") do
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp jobs(trigger) do
    Fanfarr.Repo.all(Oban.Job)
    |> Enum.filter(&(&1.worker == "Fanfarr.Workers.Backup" and &1.args["trigger"] == trigger))
  end

  describe "the copy itself" do
    test "a snapshot is a database SQLite vouches for, with the schema in it", %{dir: dir} do
      assert {:ok, path} = Backup.snapshot(dir)

      assert File.exists?(path)
      assert File.stat!(path).size > 0
      assert File.read!(path) |> binary_part(0, 16) == "SQLite format 3\0"
      assert Backup.validate(path) == :ok

      # And it can be opened and read, which is the only proof that matters.
      {:ok, db} = Exqlite.Sqlite3.open(path)

      try do
        {:ok, statement} = Exqlite.Sqlite3.prepare(db, "select count(*) from library_media_items")
        assert {:row, [count]} = Exqlite.Sqlite3.step(db, statement)
        assert is_integer(count)
      after
        Exqlite.Sqlite3.close(db)
      end
    end

    test "anything that is not a database is refused", %{dir: dir} do
      path = write(dir, "fanfarr-20200101-000000.sqlite", "hello, I am not a database")

      assert {:error, :not_a_database} = Backup.validate(path)
      assert {:error, :enoent} = Backup.validate(Path.join(dir, "nothing-here.sqlite"))
    end

    test "a snapshot writes metadata beside it", %{dir: dir} do
      {:ok, path} = Backup.snapshot(dir)

      metadata = Backup.metadata(path)
      assert is_map(metadata)
      assert metadata["version"] =~ ~r/\d+\.\d+\.\d+/
      assert is_integer(metadata["bytes"])
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(metadata["taken_at"])
    end

    test "a directory that cannot be created is an error, with no file left behind" do
      blocker =
        Path.join(System.tmp_dir!(), "fanfarr-blocker-#{System.unique_integer([:positive])}")

      File.write!(blocker, "I am a file, not a directory")
      on_exit(fn -> File.rm(blocker) end)

      # A backup directory *inside* a file can never be made. This is the
      # root-proof stand-in for an unwritable directory, which is the failure
      # that produced no snapshot, no error and no log line.
      assert {:error, _reason} = Backup.snapshot(Path.join(blocker, "backups"))
    end
  end

  describe "what is due" do
    test "due when there is nothing, and not due once there is something fresh", %{dir: dir} do
      assert Backup.due?(dir)

      {:ok, _path} = Backup.snapshot(dir)
      refute Backup.due?(dir)
    end

    test "due when the newest is older than the interval", %{dir: dir} do
      # The name is the time the snapshot was taken, and that is what the
      # interval is measured from. It does not have to be a valid database to
      # answer this question -- only the schedule is being asked.
      write(dir, "fanfarr-20200101-000000.sqlite")

      assert Backup.due?(dir)
    end

    test "an interval of 0 means off, the same as every other interval", %{dir: dir} do
      Fanfarr.Settings.put_setting!("backup_interval_hours", "0")

      assert Backup.interval_hours() == nil
      refute Backup.due?(dir)
    end

    test "the switch turns the schedule off without turning the feature off", %{dir: dir} do
      Fanfarr.Settings.put_setting!("backup_enabled", "false")

      refute Backup.enabled?()
      refute Backup.due?(dir)

      # Still allowed by hand: the switch is about what happens unattended.
      assert {:ok, _path} = Backup.snapshot(dir)
    end

    test "settings fall back rather than failing the heartbeat" do
      assert Backup.keep() == 7
      assert Backup.interval_hours() == 24

      Fanfarr.Settings.put_setting!("backup_keep", "3")
      Fanfarr.Settings.put_setting!("backup_interval_hours", "6")
      assert Backup.keep() == 3
      assert Backup.interval_hours() == 6

      Fanfarr.Settings.put_setting!("backup_keep", "seven")
      Fanfarr.Settings.put_setting!("backup_interval_hours", "soon")
      assert Backup.keep() == 7
      assert Backup.interval_hours() == 24
    end
  end

  describe "pruning" do
    test "keeps the newest and deletes the rest of ours", %{dir: dir} do
      for n <- 1..4, do: write(dir, "fanfarr-2026010#{n}-120000.sqlite")

      assert Backup.prune(dir, 2) == %{deleted: 2, failed: 0}
      assert length(Backup.list(dir)) == 2

      names = Backup.list(dir) |> Enum.map(& &1.name)
      assert names == Enum.sort(names, :desc)
    end

    test "never deletes a database it did not write", %{dir: dir} do
      # The bug this exists for: the first version globbed *.sqlite, so a
      # database an operator had copied in -- the one they would want back --
      # was deleted by the rotation.
      theirs = write(dir, "mydatabase.sqlite")
      for n <- 1..3, do: write(dir, "fanfarr-2026010#{n}-120000.sqlite")

      Backup.prune(dir, 1)

      assert File.exists?(theirs)
      assert Backup.list(dir) |> Enum.find(&(&1.path == theirs)) |> Map.get(:kind) == :foreign
    end

    test "pre-restore snapshots outlive a rotation, but not forever", %{dir: dir} do
      for n <- 1..4, do: write(dir, "pre-restore-2026010#{n}-120000.sqlite")
      for n <- 1..3, do: write(dir, "fanfarr-2026010#{n}-120000.sqlite")

      Backup.prune(dir, 1)

      pre_restore = Backup.list(dir) |> Enum.filter(&(&1.kind == :pre_restore))
      assert length(pre_restore) == 2
    end

    test "never deletes the snapshot just written", %{dir: dir} do
      {:ok, path} = Backup.snapshot(dir)

      # keep 1 with the fresh one excluded: the rotation has nothing it may
      # touch, so the file that was just verified stays.
      assert Backup.prune(dir, 1, exclude: path) == %{deleted: 0, failed: 0}
      assert File.exists?(path)
    end

    test "a single snapshot is never rotated away", %{dir: dir} do
      {:ok, path} = Backup.snapshot(dir)
      Backup.prune(dir, 1)
      assert File.exists?(path)
    end
  end

  describe "the listing" do
    test "reads the time out of the name", %{dir: dir} do
      {:ok, path} = Backup.snapshot(dir)

      snapshot = Backup.newest(dir)
      assert snapshot.path == path
      assert %DateTime{year: 2026} = snapshot.taken_at
      assert snapshot.kind == :auto
      assert snapshot.bytes == File.stat!(path).size
    end

    test "totals up for the settings page", %{dir: dir} do
      assert Backup.usage(dir) == %{count: 0, bytes: 0, newest: nil}

      {:ok, path} = Backup.snapshot(dir)
      usage = Backup.usage(dir)

      assert usage.count == 1
      assert usage.bytes == File.stat!(path).size
      assert usage.newest.path == path
    end

    test "a file that cannot be read is listed rather than raising", %{dir: dir} do
      # A dangling symlink, which is what a copied-in file or a half-deleted
      # one can look like. This runs inside the scheduler, so raising here
      # would take out the tick that enqueues everything else.
      link = Path.join(dir, "fanfarr-20260101-120000.sqlite")
      File.ln_s!("/nonexistent/target", link)

      snapshot = Backup.list(dir) |> Enum.find(&(&1.path == link))
      assert snapshot.bytes == nil
      assert %DateTime{year: 2026} = snapshot.taken_at
    end

    test "kind/1 tells ours from theirs" do
      assert Backup.kind("fanfarr-20260101-120000.sqlite") == :auto
      assert Backup.kind("pre-restore-20260101-120000.sqlite") == :pre_restore
      assert Backup.kind("mydatabase.sqlite") == :foreign
    end
  end

  describe "the worker" do
    setup %{dir: dir} do
      Fanfarr.Settings.put_setting!("backup_dir", dir)
      :ok
    end

    test "the heartbeat queues a snapshot only when one is due", %{dir: dir} do
      assert {:ok, _job} = BackupWorker.enqueue_if_due()

      # Read back rather than off the struct returned by `new/1`: once Oban has
      # stored it the args are string-keyed, which is what perform/1 matches on.
      assert [job] = jobs("auto")
      assert job.args["trigger"] == "auto"

      # Not due any more, so the next tick asks for nothing.
      {:ok, _path} = Backup.snapshot(dir)
      assert :ok = BackupWorker.enqueue_if_due()
      assert length(jobs("auto")) == 1
    end

    test "a second press inside the minute is one snapshot, not an error", %{dir: dir} do
      assert {:ok, _job} = BackupWorker.enqueue_now()
      assert :ok = BackupWorker.enqueue_now()
      assert length(jobs("manual")) == 1

      # Nothing has been performed yet, so a snapshot is still due.
      assert Backup.due?(dir)
    end

    test "Back up now ignores the switch, because it is not unattended" do
      Fanfarr.Settings.put_setting!("backup_enabled", "false")

      assert {:ok, _job} = BackupWorker.enqueue_now()
      assert [job] = jobs("manual")
      assert job.args["trigger"] == "manual"
    end

    test "performing the job takes the snapshot", %{dir: dir} do
      assert :ok = BackupWorker.perform(%Oban.Job{args: %{"trigger" => "manual"}})

      assert [%{bytes: bytes} | _] = Backup.list(dir)
      assert bytes > 0
      refute Backup.due?(dir)
    end
  end
end
