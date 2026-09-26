defmodule Fanfarr.BackupTest do
  @moduledoc """
  Snapshots of the live database.

  The rows a test writes are invisible to a snapshot, and that is correct
  rather than a limitation being worked around: every test runs inside the
  sandbox transaction, and a second connection -- which is what a backup is --
  cannot see uncommitted work by design. So what is asserted here is that the
  copy is a real, whole, openable database with the schema in it, which is the
  part that could plausibly be wrong.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Backup

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-backup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp query(path, sql) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
    result = Exqlite.Sqlite3.step(db, statement)
    Exqlite.Sqlite3.release(db, statement)
    Exqlite.Sqlite3.close(db)
    result
  end

  test "it writes a whole database, not an empty file", %{dir: dir} do
    assert {:ok, path} = Backup.snapshot(dir)

    assert File.exists?(path)
    assert File.stat!(path).size > 0
    # Every SQLite file starts with these sixteen bytes.
    assert File.read!(path) |> binary_part(0, 16) == "SQLite format 3\0"

    # And it is a database SQLite is willing to vouch for, with the schema in
    # it: a snapshot that opened but had no tables would be worse than none,
    # because it would look like a backup.
    assert {:row, ["ok"]} = query(path, "pragma integrity_check")

    assert {:row, [1]} =
             query(path, "select count(*) from sqlite_master where name = 'library_media_items'")
  end

  test "it is due when there is nothing, and fresh once there is", %{dir: dir} do
    assert Backup.due?(dir)

    assert {:ok, _path} = Backup.snapshot(dir)

    refute Backup.due?(dir)
  end

  test "it is never due when the switch is off", %{dir: dir} do
    Fanfarr.Settings.put_setting!("backup_enabled", "false")

    refute Backup.enabled?()
    refute Backup.due?(dir)
    assert :ok = Backup.run_if_due(dir)
    assert Backup.list(dir) == []
  end

  test "pruning keeps the newest and deletes the rest", %{dir: dir} do
    for _ <- 1..4, do: assert({:ok, _} = Backup.snapshot(dir))

    assert length(Backup.list(dir)) == 4

    # Explicit keep rather than the setting: this is about the pruning rule.
    assert Backup.prune(dir, 2) == 2
    assert length(Backup.list(dir)) == 2

    names = Backup.list(dir) |> Enum.map(& &1.name)
    assert names == Enum.sort(names, :desc)
  end

  test "the newest snapshot is the first one listed", %{dir: dir} do
    assert Backup.newest(dir) == nil

    {:ok, first} = Backup.snapshot(dir)
    {:ok, second} = Backup.snapshot(dir)

    refute first == second
    assert Backup.newest(dir) == List.first(Backup.list(dir))
    assert Backup.newest(dir).name >= Path.basename(first)
  end

  test "the settings have sane defaults and refuse nonsense" do
    assert Backup.keep() == 7
    assert Backup.interval_hours() == 24

    Fanfarr.Settings.put_setting!("backup_keep", "3")
    Fanfarr.Settings.put_setting!("backup_interval_hours", "6")
    assert Backup.keep() == 3
    assert Backup.interval_hours() == 6

    # A value that is not a positive integer falls back rather than failing the
    # heartbeat: a typo in a setting must not stop the backups.
    Fanfarr.Settings.put_setting!("backup_keep", "seven")
    Fanfarr.Settings.put_setting!("backup_interval_hours", "0")
    assert Backup.keep() == 7
    assert Backup.interval_hours() == 24
  end
end
