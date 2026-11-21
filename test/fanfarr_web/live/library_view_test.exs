defmodule FanfarrWeb.LibraryViewTest do
  @moduledoc """
  The library section's view preferences and outbound links: which columns the
  table draws, how that choice is remembered, and where the ids on an item page
  point.
  """
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item = fn attrs ->
      Fanfarr.Library.sync_media_item_from_plex!(
        Map.merge(
          %{
            plex_rating_key: "rk-#{System.unique_integer([:positive])}",
            title: "Untitled",
            kind: :show,
            section_id: section.id
          },
          attrs
        )
      )
    end

    # One item always, so the table itself draws: it only renders when there is
    # a row to render, and a test about headers would otherwise be testing an
    # empty page.
    item.(%{title: "Seed"})

    %{item: item}
  end

  # A column is drawn when its header is in the table.
  defp drawn?(view, label), do: has_element?(view, "th", label)

  defp saved_columns do
    Fanfarr.Settings.list_settings!()
    |> Enum.find_value(fn setting -> setting.key == "library_columns" && setting.value end)
  end

  describe "the column picker" do
    test "the table opens with the working set, and the extras stay out of it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/library")

      assert drawn?(view, "Title")
      assert drawn?(view, "Theme")
      assert drawn?(view, "Size")

      # These two arrived later and are references rather than the working
      # view, so they are asked for rather than inflicted.
      refute drawn?(view, "Added")
      refute drawn?(view, "Seasons")
    end

    test "?cols= draws exactly those columns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/library?cols=title,seasons")

      assert drawn?(view, "Title")
      assert drawn?(view, "Seasons")
      refute drawn?(view, "Year")
      refute drawn?(view, "Theme")
    end

    test "an unknown name in the parameter is ignored, not fatal", %{conn: conn} do
      # A hand-edited URL should show fewer columns, not raise.
      {:ok, view, _html} = live(conn, "/library?cols=title,nonsense")

      assert drawn?(view, "Title")
      refute drawn?(view, "Seasons")
    end

    test "saving writes the setting, and a plain visit then uses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/library")

      view |> element("button", "Columns") |> render_click()
      assert has_element?(view, "#library-columns")

      view
      |> form("#library-columns", %{"cols" => ["title", "seasons", "added"]})
      |> render_submit()

      assert saved_columns() == "title,added,seasons"

      # No parameter: the saved set answers.
      {:ok, view, _html} = live(conn, "/library")
      assert drawn?(view, "Seasons")
      assert drawn?(view, "Added")
      refute drawn?(view, "Year")
    end

    test "the parameter does not overwrite the setting", %{conn: conn} do
      # A one-off view is a one-off view.
      {:ok, _view, _html} = live(conn, "/library?cols=title,seasons")
      refute saved_columns()

      {:ok, view, _html} = live(conn, "/library")
      assert drawn?(view, "Year")
      refute drawn?(view, "Seasons")
    end

    test "escape closes the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/library")
      view |> element("button", "Columns") |> render_click()

      assert has_element?(
               view,
               ~s(div[phx-window-keydown="close_columns"][phx-key="Escape"])
             )
    end

    test "title is kept whatever else is chosen", %{conn: conn} do
      # Title is the floor: a table with no columns is not a view anyone can
      # read, so it stays even when it was not the thing ticked.
      {:ok, view, _html} = live(conn, "/library")
      view |> element("button", "Columns") |> render_click()
      view |> form("#library-columns", %{"cols" => ["seasons"]}) |> render_submit()

      assert saved_columns() == "title,seasons"

      {:ok, view, _html} = live(conn, "/library")
      assert drawn?(view, "Title")
      assert drawn?(view, "Seasons")
    end
  end

  describe "the new columns" do
    defp order(html) do
      Regex.scan(~r/(Early|Late|Film|Seed)/, html) |> Enum.map(&List.last/1) |> Enum.uniq()
    end

    test "they draw what Plex reported", %{conn: conn, item: item} do
      # Midday, deliberately: the date is rendered in the appliance's zone, and
      # midnight UTC is the previous day anywhere west of Greenwich.
      item.(%{
        title: "Early",
        added_at: ~U[2020-01-01 12:00:00.000000Z],
        season_count: 2
      })

      {:ok, view, _html} = live(conn, "/library?cols=title,added,seasons")

      assert has_element?(view, "td", "2")
      # The date is Plex's, rendered in the appliance's zone.
      assert has_element?(view, "td", "1 Jan 2020")
    end

    test "a film has no season count, and shows a dash rather than a nought",
         %{conn: conn, item: item} do
      item.(%{title: "Film", kind: :movie, added_at: nil, season_count: nil})

      {:ok, view, _html} = live(conn, "/library?cols=title,added,seasons")

      assert has_element?(view, "td", "—")
    end

    test "sorting by added puts the newest first and the undated last",
         %{conn: conn, item: item} do
      item.(%{title: "Early", added_at: ~U[2020-01-01 12:00:00.000000Z]})
      item.(%{title: "Late", added_at: ~U[2024-01-01 12:00:00.000000Z]})
      item.(%{title: "Film", kind: :movie, added_at: nil})

      {:ok, _view, html} = live(conn, "/library?cols=title,added&sort=-added")
      assert order(html) |> Enum.take(2) == ["Late", "Early"]

      # A date we do not have is not the oldest date: the undated ones go last
      # together, in title order.
      assert order(html) |> Enum.drop(2) |> Enum.sort() == ["Film", "Seed"]
    end

    test "sorting by seasons puts the longest running first", %{conn: conn, item: item} do
      item.(%{title: "Early", season_count: 2})
      item.(%{title: "Late", season_count: 12})
      item.(%{title: "Film", kind: :movie, season_count: nil})

      {:ok, _view, html} = live(conn, "/library?cols=title,seasons&sort=-seasons")
      assert order(html) |> Enum.take(2) == ["Late", "Early"]

      # A film has no seasons, and neither has a show Plex has not scanned:
      # both go last rather than counting as zero.
      assert order(html) |> Enum.drop(2) |> Enum.sort() == ["Film", "Seed"]
    end
  end

  describe "source links on the item page" do
    test "each id links to its own site", %{conn: conn, item: item} do
      item =
        item.(%{
          title: "A Bug's Life",
          kind: :movie,
          imdb_id: "tt0120623",
          tmdb_id: "9487",
          tvdb_id: "708"
        })

      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      assert has_element?(
               view,
               ~s(a[href="https://www.imdb.com/title/tt0120623/"]),
               "imdb:tt0120623"
             )

      assert has_element?(
               view,
               ~s(a[href="https://www.themoviedb.org/movie/9487"]),
               "tmdb:9487"
             )

      assert has_element?(
               view,
               ~s(a[href="https://www.thetvdb.com/dereferrer/movie/708"]),
               "tvdb:708"
             )
    end

    test "a show links to the television pages", %{conn: conn, item: item} do
      item = item.(%{title: "Breaking Bad", tmdb_id: "1396", tvdb_id: "81189"})

      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      assert has_element?(view, ~s(a[href="https://www.themoviedb.org/tv/1396"]))
      assert has_element?(view, ~s(a[href="https://www.thetvdb.com/dereferrer/series/81189"]))
    end

    test "an item with no ids shows a dash and no link", %{conn: conn, item: item} do
      item = item.(%{title: "Nothing Identified"})

      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      refute has_element?(view, ~s(a[href*="imdb.com"]))
      refute has_element?(view, ~s(a[href*="themoviedb.org"]))
      refute has_element?(view, ~s(a[href*="thetvdb.com"]))
    end
  end

  describe "bulk lengths" do
    test "sets the crop length for the whole selection", %{conn: conn, item: item} do
      a = item.(%{title: "A"})
      b = item.(%{title: "B"})
      {:ok, view, _html} = live(conn, "/library")

      view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
      view |> element(~s(input[phx-value-id="#{b.id}"])) |> render_click()
      view |> element("button", "Lengths") |> render_click()

      html =
        view
        |> form("#library-lengths", %{"seconds" => "45", "duration" => "leave"})
        |> render_submit()

      assert html =~ "Updated 2 titles"
      assert Fanfarr.Library.get_media_item!(a.id).crop_target_ms == 45_000
      assert Fanfarr.Library.get_media_item!(b.id).crop_target_ms == 45_000
    end

    test "blank seconds leaves the crop, the duration tri-state applies",
         %{conn: conn, item: item} do
      a = item.(%{title: "A"})
      {:ok, view, _html} = live(conn, "/library")

      view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
      view |> element("button", "Lengths") |> render_click()

      view
      |> form("#library-lengths", %{"seconds" => "", "duration" => "ignore"})
      |> render_submit()

      reloaded = Fanfarr.Library.get_media_item!(a.id)
      assert is_nil(reloaded.crop_target_ms)
      assert reloaded.ignore_duration_limit

      view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
      view |> element("button", "Lengths") |> render_click()

      view
      |> form("#library-lengths", %{"seconds" => "", "duration" => "respect"})
      |> render_submit()

      refute Fanfarr.Library.get_media_item!(a.id).ignore_duration_limit
    end

    test "nonsense seconds are refused", %{conn: conn, item: item} do
      a = item.(%{title: "A"})
      {:ok, view, _html} = live(conn, "/library")

      view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
      view |> element("button", "Lengths") |> render_click()

      html =
        view
        |> form("#library-lengths", %{"seconds" => "2", "duration" => "leave"})
        |> render_submit()

      assert html =~ "from 5 to 900"
      assert is_nil(Fanfarr.Library.get_media_item!(a.id).crop_target_ms)
    end

    test "clear to global unsets the override", %{conn: conn, item: item} do
      a = item.(%{title: "A"})
      {:ok, _} = Fanfarr.Library.set_crop_target(a, %{crop_target_ms: 45_000})
      {:ok, view, _html} = live(conn, "/library")

      view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
      view |> element("button", "Lengths") |> render_click()

      html = view |> element("button", "Clear to global") |> render_click()
      assert html =~ "Cleared 1 titles"
      assert is_nil(Fanfarr.Library.get_media_item!(a.id).crop_target_ms)
    end

    test "bulk apply asks first", %{conn: conn, item: item} do
      a = item.(%{title: "A"})
      {:ok, view, _html} = live(conn, "/library")

      view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
      assert has_element?(view, ~s(button[data-confirm*="cannot be undone"]))
    end
  end

  describe "director filter" do
    test "narrows the table, and the URL carries it", %{conn: conn, item: item} do
      item.(%{title: "Memento", kind: :movie, directors: ["Christopher Nolan"]})
      item.(%{title: "Other", kind: :movie, directors: ["Someone Else"]})

      {:ok, _view, html} = live(conn, "/library?director=Christopher+Nolan")
      assert html =~ "Memento"
      refute html =~ ">Other<"

      # And the dropdown offers it without a query string.
      {:ok, view, _} = live(conn, "/library")
      assert has_element?(view, "select[name=director] option", "Christopher Nolan")
    end

    test "a director on the item page links to the filtered library",
         %{conn: conn, item: item} do
      picked = item.(%{title: "Memento", kind: :movie, directors: ["Christopher Nolan"]})
      {:ok, view, _html} = live(conn, "/library/#{picked.id}")

      assert has_element?(
               view,
               ~s(a[title="Everything by Christopher Nolan"]),
               "Christopher Nolan"
             )
    end
  end
end
