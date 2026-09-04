defmodule FanfarrWeb.ActivityLiveTest do
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  setup :register_and_log_in_user

  setup do
    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "One Piece",
        kind: :show
      })

    %{item: item}
  end

  defp enqueue(worker, args, state) do
    {:ok, job} = worker.new(args) |> Oban.insert()

    Fanfarr.Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: state]
    )

    job
  end

  test "an estimate appears once there is history to base one on", %{conn: conn, item: item} do
    done =
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false}, "completed")

    Fanfarr.Repo.update_all(
      from(j in Oban.Job, where: j.id == ^done.id),
      set: [
        attempted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second),
        completed_at: NaiveDateTime.utc_now()
      ]
    )

    for n <- 1..4 do
      enqueue(
        Fanfarr.Workers.ApplyTheme,
        %{media_item_id: item.id, dry_run: false, theme_url: "https://example.com/#{n}"},
        "available"
      )
    end

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "4 waiting"
    assert html =~ "about 2 minutes left"
  end

  test "no estimate is shown before there is anything to measure", %{conn: conn, item: item} do
    enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false}, "available")

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "1 waiting"
    refute html =~ "left."
  end

  test "the Stop button is hidden with nothing queued", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/activity")
    refute html =~ "Stop bulk theme work"
  end

  test "the Stop button cancels queued and running theme work", %{conn: conn, item: item} do
    enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: true}, "available")
    enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id}, "executing")

    {:ok, view, html} = live(conn, "/activity")
    assert html =~ "Stop bulk theme work"
    # Stopping is not destructive -- nothing already applied is undone -- so
    # it does not stop to ask first.
    refute html =~ "data-confirm"

    html = view |> element("button", "Stop bulk theme work") |> render_click()

    assert html =~ "Stopped 2 queued or running theme job(s)"
    refute html =~ "Stop bulk theme work"
    refute Fanfarr.Jobs.bulk_theme_work_pending?()
  end

  test "the Stop button leaves other work untouched", %{conn: conn, item: item} do
    enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "available")
    sync = enqueue(Fanfarr.Workers.RefreshThemerr, %{}, "available")

    {:ok, view, _html} = live(conn, "/activity")
    view |> element("button", "Stop bulk theme work") |> render_click()

    assert Fanfarr.Repo.get(Oban.Job, sync.id).state == "available"
  end
end
