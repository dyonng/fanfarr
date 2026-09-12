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

  describe "the queue table" do
    test "the columns are headed, and the action is named once", %{conn: conn, item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      {:ok, view, _html} = live(conn, "/activity")

      for header <- ~w(Action Item State Queued Started Took Details) do
        assert has_element?(view, "th", header)
      end

      # It used to print the label and then the worker module under it, so
      # every apply row read "Apply theme" and then "ApplyTheme" -- the same
      # fact twice, once in English and once in Elixir.
      html = render(view)
      assert html =~ "Apply theme"
      refute html =~ "ApplyTheme"
    end

    test "the attempt count shows only once it is not the first", %{conn: conn, item: item} do
      # It had a column to itself reading "attempt 1/3" on every row, which is
      # the answer to a question nobody asked.
      job = enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      refute render(live_view(conn)) =~ "×2"

      Fanfarr.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [attempt: 2])
      assert render(live_view(conn)) =~ "×2"
    end

    test "times are the server's, rendered without JavaScript", %{conn: conn, item: item} do
      # The appliance's own zone, from TZ, not the reader's browser: one
      # server answers one way, so a phone and a desktop agree. The relative
      # reading is what the page is asked for and it comes out of the server,
      # so the table is correct in a browser with no JavaScript at all.
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      html = render(live_view(conn))

      assert html =~ "just now"
      assert html =~ "times in #{Fanfarr.Clock.zone()}"

      # The machine-readable instant stays on the element regardless.
      assert html =~ "<time"
      assert html =~ "datetime="

      # No hook, and no per-cell zone label: it is stated once in the header.
      refute html =~ "LocalTime"
      refute html =~ "data-local"
    end

    test "the recent theme failures section is gone", %{conn: conn} do
      refute render(live_view(conn)) =~ "Recent theme failures"
    end
  end

  describe "paging" do
    test "a long queue pages rather than being cut off", %{conn: conn, item: item} do
      for _ <- 1..(Fanfarr.Jobs.history_page_size() + 5) do
        enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")
      end

      {:ok, view, _html} = live(conn, "/activity")

      assert has_element?(view, ~s(nav[aria-label*="Pagination"]))
      assert render(view) =~ "Page 1 of 2"

      # The page is in the URL, so it survives a refresh and can be linked.
      {:ok, second, _html} = live(conn, "/activity?page=2")
      assert render(second) =~ "Page 2 of 2"
      assert length(rows(second)) == 5
    end

    test "one page of jobs shows no pager at all", %{conn: conn, item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      refute has_element?(live_view(conn), ~s(nav[aria-label*="Pagination"]))
    end

    test "a page number past the end lands on the last one", %{conn: conn, item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      assert length(rows(live_view(conn, "/activity?page=99"))) == 1
    end

    test "a page number that is not a number is not an error", %{conn: conn, item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      assert length(rows(live_view(conn, "/activity?page=drop%20table"))) == 1
    end
  end

  defp live_view(conn, path \\ "/activity") do
    {:ok, view, _html} = live(conn, path)
    view
  end

  # Counted off the row ids rather than parsed: Floki is not a dependency here,
  # and every row already carries its job id as a marker.
  defp rows(view) do
    Regex.scan(~r/id="job-\d+"/, render(view))
  end

  test "an estimate appears once there is history to base one on", %{conn: conn, item: item} do
    done =
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

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
        %{media_item_id: item.id, theme_url: "https://example.com/#{n}"},
        "available"
      )
    end

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "4 waiting"
    assert html =~ "about 2 minutes left"
  end

  test "no estimate is shown before there is anything to measure", %{conn: conn, item: item} do
    enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "available")

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "1 waiting"
    refute html =~ "left."
  end

  test "the Stop button is hidden with nothing queued", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/activity")
    refute html =~ "Stop bulk theme work"
  end

  test "the Stop button cancels queued and running theme work", %{conn: conn, item: item} do
    enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "available")
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
