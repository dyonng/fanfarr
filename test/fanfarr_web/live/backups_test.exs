defmodule FanfarrWeb.BackupsTest do
  @moduledoc """
  The Backups card in Settings, and the download it offers.

  A snapshot is the whole database, which means it carries the Plex token and
  the dashboard's password hash. So the parts worth asserting are the ones that
  keep it from being handed out carelessly: a signed-in session, an attachment,
  and no caching -- plus that the card tells the truth about what exists.
  """
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-card-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Fanfarr.Settings.put_setting!("backup_dir", dir)
    %{dir: dir}
  end

  defp snapshot_in(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "SQLite format 3\0 pretending to be a database")
    path
  end

  # The click hands the work to a task, because a snapshot reads the whole
  # database -- so the assertion has to wait for it rather than assume.
  defp eventually(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(check, attempts - 1)
    end
  end

  defp backup_jobs do
    Fanfarr.Repo.all(Oban.Job)
    |> Enum.filter(&(&1.worker == "Fanfarr.Workers.Backup"))
  end

  describe "the card" do
    test "counts the snapshots and says how much room they take", %{conn: conn, dir: dir} do
      snapshot_in(dir, "fanfarr-20260926-120000.sqlite")
      snapshot_in(dir, "fanfarr-20260926-130000.sqlite")

      {:ok, view, _html} = live(conn, "/settings")

      assert has_element?(view, "#backups-card")
      assert render(view) =~ "2 snapshots"
      assert render(view) =~ dir
    end

    test "says none yet when there are none", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      assert render(view) =~ "none yet"
    end

    test "a file it did not write is listed, marked, and not deletable",
         %{conn: conn, dir: dir} do
      # The data-loss rule, visible in the UI: the rotation leaves other
      # people's databases alone, and so does the delete button.
      snapshot_in(dir, "mydatabase.sqlite")

      {:ok, view, _html} = live(conn, "/settings")

      assert render(view) =~ "mydatabase.sqlite"
      assert render(view) =~ "not written by Fanfarr"
      refute has_element?(view, ~s(button[phx-click="delete_backup"]))
    end
  end

  describe "saving the settings" do
    test "the interval and the count are stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("#backups-form",
        backup_enabled: "true",
        backup_interval_hours: "6",
        backup_keep: "3"
      )
      |> render_submit()

      assert Fanfarr.Backup.interval_hours() == 6
      assert Fanfarr.Backup.keep() == 3
    end

    test "0 is stored as off, not as blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("#backups-form", backup_interval_hours: "0", backup_keep: "7")
      |> render_submit()

      # Blank would mean "use the default", which is the opposite of what 0
      # means for an interval here.
      assert Fanfarr.Config.get("backup_interval_hours") == "0"
      assert Fanfarr.Backup.interval_hours() == nil
      refute Fanfarr.Backup.due?(Fanfarr.Backup.dir())
    end

    test "nonsense is refused rather than stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html = view |> form("#backups-form", backup_interval_hours: "soon") |> render_submit()

      assert html =~ "0 to turn the schedule off"
      assert Fanfarr.Backup.interval_hours() == 24
      assert has_element?(view, "#backups-form")
    end

    test "the switch is stored, and off does not stop a manual snapshot", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      # Not `form/3`: it validates against the *rendered* value of a checkbox,
      # which is "true" because the default is on. Sending the data explicitly
      # is the only way to say "off" here -- and the handler is what decides the
      # meaning, so this is the honest way to test it.
      view
      |> element("#backups-form")
      |> render_submit(%{
        "backup_enabled" => "false",
        "backup_interval_hours" => "24",
        "backup_keep" => "7"
      })

      refute Fanfarr.Backup.enabled?()

      # Still allowed by hand, which is the whole distinction the switch makes.
      assert {:ok, _} = Fanfarr.Workers.Backup.enqueue_now()
    end
  end

  describe "backing up on demand" do
    test "Back up now queues the worker", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view |> element(~s(button[phx-click="backup_now"])) |> render_click()

      assert eventually(fn -> backup_jobs() != [] end)
      assert [job] = backup_jobs()
      assert job.args["trigger"] == "manual"
    end
  end

  describe "deleting a snapshot" do
    test "removes the file and the metadata beside it", %{conn: conn, dir: dir} do
      path = snapshot_in(dir, "fanfarr-20260926-120000.sqlite")
      File.write!(path <> ".json", "{}")

      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(
        ~s(button[phx-click="delete_backup"][phx-value-name="fanfarr-20260926-120000.sqlite"])
      )
      |> render_click()

      refute File.exists?(path)
      refute File.exists?(path <> ".json")
      assert render(view) =~ "none yet"
    end
  end

  describe "restoring" do
    setup do
      # A real snapshot: staging validates the file, so a fixture would be
      # refused before the flow under test had begun.
      dir = Fanfarr.Backup.dir()
      File.mkdir_p!(dir)
      {:ok, path} = Fanfarr.Backup.snapshot(dir)
      on_exit(fn -> Fanfarr.Backup.Restore.cancel() end)
      %{snapshot: Path.basename(path)}
    end

    defp ask(view, snapshot) do
      view
      |> element(~s(button[phx-click="restore_ask"][phx-value-name="#{snapshot}"]))
      |> render_click()
    end

    test "asks for the word before it will replace anything", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, "/settings")
      ask(view, snapshot)

      assert has_element?(view, "form[phx-submit=restore_confirm]")
      assert Fanfarr.Backup.Restore.pending() == nil
    end

    test "the wrong word is refused", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, "/settings")
      ask(view, snapshot)

      html =
        view
        |> form("form[phx-submit=restore_confirm]", %{"name" => snapshot, "confirm" => "yes"})
        |> render_submit()

      # The word, not the quoted phrase: HEEx escapes the quotes in the flash,
      # so matching the phrase as written would fail on the markup, not on the
      # behaviour.
      assert html =~ "to confirm"
      assert Fanfarr.Backup.Restore.pending() == nil
    end

    test "the right word stages it, and keeps what it is about to replace",
         %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, "/settings")
      ask(view, snapshot)

      view
      |> form("form[phx-submit=restore_confirm]", %{"name" => snapshot, "confirm" => "restore"})
      |> render_submit()

      pending = Fanfarr.Backup.Restore.pending()
      assert pending["source"] == snapshot
      # The undo button for the decision just made.
      assert Enum.any?(Fanfarr.Backup.list(), &(&1.kind == :pre_restore))

      # And the card says one is waiting. No restart happens here: the suite
      # sets restart_on_restore false, which is why this test can end.
      assert render(view) =~ "is staged"
    end

    test "a snapshot kept elsewhere can be uploaded instead", %{conn: conn, dir: dir} do
      # The case with no snapshot on disk to choose: the disk that held them is
      # the thing that failed.
      {:ok, snapshot} = Fanfarr.Backup.snapshot(dir)
      elsewhere = Path.join(dir, "from-elsewhere.sqlite")
      File.cp!(snapshot, elsewhere)

      {:ok, view, _html} = live(conn, "/settings")

      view
      |> file_input("#restore-upload-form", :snapshot, [
        %{name: "from-elsewhere.sqlite", content: File.read!(elsewhere)}
      ])
      |> render_upload("from-elsewhere.sqlite")

      view |> element("#restore-upload-form") |> render_submit()

      assert Fanfarr.Backup.Restore.pending()["source"] == "an uploaded file"
    end

    test "an uploaded file that is not a database is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> file_input("#restore-upload-form", :snapshot, [
        %{name: "not-a-db.sqlite", content: "definitely not a database"}
      ])
      |> render_upload("not-a-db.sqlite")

      html = view |> element("#restore-upload-form") |> render_submit()

      assert html =~ "cannot be restored from"
      assert Fanfarr.Backup.Restore.pending() == nil
    end

    test "a staged restore can be cancelled", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, "/settings")
      ask(view, snapshot)

      view
      |> form("form[phx-submit=restore_confirm]", %{"name" => snapshot, "confirm" => "restore"})
      |> render_submit()

      view |> element(~s(button[phx-click="cancel_restore"])) |> render_click()

      assert Fanfarr.Backup.Restore.pending() == nil
    end
  end

  describe "the download" do
    test "sends the snapshot as an attachment, never cached", %{conn: conn, dir: dir} do
      name = "fanfarr-20260926-120000.sqlite"
      snapshot_in(dir, name)

      conn = get(conn, "/backups/#{name}")

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-disposition")) =~ "attachment"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ name
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "refuses a name that is not one of ours", %{conn: conn, dir: dir} do
      # A file that exists, but not in the backup directory: the name in the
      # URL is matched against the snapshots on disk, never used as a path.
      outside = Path.join(Path.dirname(dir), "fanfarr-20260926-140000.sqlite")
      File.write!(outside, "not yours")
      on_exit(fn -> File.rm(outside) end)

      assert get(conn, "/backups/fanfarr-20260926-140000.sqlite").status == 404
      assert get(conn, "/backups/nothing-here.sqlite").status == 404
    end
  end
end
