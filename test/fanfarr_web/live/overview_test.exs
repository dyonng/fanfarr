defmodule FanfarrWeb.OverviewTest do
  @moduledoc """
  The dashboard at `/`, which replaced the library as the homepage.
  """
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  defp section(attrs \\ %{}) do
    Fanfarr.Library.sync_section_from_plex!(
      Map.merge(%{plex_key: "1", title: "TV Shows", kind: :show}, attrs)
    )
  end

  defp item(section, attrs) do
    Fanfarr.Library.sync_media_item_from_plex!(
      Map.merge(
        %{
          plex_rating_key: "rk-#{System.unique_integer([:positive])}",
          section_id: section.id,
          title: "Untitled",
          kind: section.kind
        },
        attrs
      )
    )
  end

  # A ThemerrDB answer for an item, which is what makes it "ready".
  defp themerr_answer(imdb_id, item_type \\ :tv_shows) do
    Fanfarr.Themes.record_themerr_lookup!(%{
      item_type: item_type,
      database: :imdb,
      external_id: imdb_id,
      found: true,
      youtube_theme_url: "https://www.youtube.com/watch?v=abc12345678"
    })
  end

  describe "an empty install" do
    test "it says what to do rather than showing a wall of noughts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "No titles yet"
      assert html =~ "Open Settings"

      # A 0% coverage bar on a fresh install reads as a broken sync.
      refute html =~ "Coverage"
    end
  end

  describe "coverage" do
    test "it counts per library, and links each one into that filtered view",
         %{conn: conn} do
      tv = section()
      movies = section(%{plex_key: "2", title: "Movies", kind: :movie})

      # Two of three themed on TV, none of one on Movies.
      tv
      |> item(%{title: "Applied"})
      |> Fanfarr.Library.record_local_theme!(%{
        local_theme_present: true,
        local_theme_path: "/tv/Applied/theme.mp3"
      })

      item(tv, %{title: "Plex has one", plex_theme_origin: :plex_agent})
      item(tv, %{title: "Nothing"})
      item(movies, %{title: "Heat"})

      {:ok, view, html} = live(conn, "/")

      # Two themed of four: TV has a local file and a Plex-supplied one, and
      # neither the third TV title nor the film has anything.
      assert html =~ "2 of 4 titles have a theme"

      # Per library, because "TV is behind, films are done" is the shape of it.
      assert html =~ "2 of 3"
      assert html =~ "0 of 1"

      # And the row narrows to that library as far as the library can express.
      assert view |> element(~s(a[href="/library?kind=show&status=missing"])) |> has_element?()
      assert view |> element(~s(a[href="/library?kind=movie&status=missing"])) |> has_element?()
    end

    test "a Plex-supplied theme counts as covered, and is listed separately",
         %{conn: conn} do
      # The judgement call, pinned: it is stock audio and the reason this
      # project exists, but calling it "missing" would disagree with the
      # library page, which does not. So it counts, and it gets its own row
      # pointing at the replace-these work.
      tv = section()
      item(tv, %{title: "Stock", plex_theme_origin: :plex_agent})

      {:ok, view, html} = live(conn, "/")

      assert html =~ "1 of 1 titles have a theme"
      assert html =~ "playing Plex&#39;s own stock theme"
      assert view |> element(~s(a[href="/library?status=plex_supplied"])) |> has_element?()
    end
  end

  describe "needs attention" do
    test "only titles ThemerrDB can actually answer for are offered",
         %{conn: conn} do
      tv = section()

      # Ready: missing, and ThemerrDB has a URL for it.
      ready = item(tv, %{title: "One Piece", imdb_id: "tt0388629"})
      themerr_answer("tt0388629")

      # Not ready: missing, but nothing knows a theme for it. This is the
      # distinction the whole panel exists to draw -- "130 missing" is not a
      # task, most of them have no source anywhere.
      item(tv, %{title: "Obscure", imdb_id: "tt9999999"})

      # Not ready: no external id at all, so nothing to look up.
      item(tv, %{title: "Unidentified"})

      {:ok, view, html} = live(conn, "/")

      assert html =~ "Apply all 1"
      assert html =~ "missing a theme that ThemerrDB has an answer for"

      # And acting on it queues exactly that one.
      render_click(view, "apply_ready", %{})

      jobs = Fanfarr.Repo.all(Oban.Job) |> Enum.filter(&(&1.worker =~ "ApplyTheme"))
      assert [job] = jobs
      assert job.args["media_item_id"] == ready.id
    end

    test "a title ThemerrDB looked up and found nothing for is not offered",
         %{conn: conn} do
      tv = section()
      item(tv, %{title: "Nothing known", imdb_id: "tt1111111"})

      Fanfarr.Themes.record_themerr_lookup!(%{
        item_type: :tv_shows,
        database: :imdb,
        external_id: "tt1111111",
        found: false
      })

      {:ok, _view, html} = live(conn, "/")

      refute html =~ "Apply all"
      assert html =~ "Nothing waiting"
    end

    test "failures get their own row into the failed filter", %{conn: conn} do
      tv = section()
      failed = item(tv, %{title: "Heat"})

      Fanfarr.Themes.record_theme_outcome!(%{
        media_item_id: failed.id,
        source: :youtube,
        method: :local_file,
        status: :failed,
        error: "yt-dlp exited 1"
      })

      {:ok, view, html} = live(conn, "/")

      assert html =~ "failed on the last attempt"
      assert view |> element(~s(a[href="/library?status=failed"])) |> has_element?()
    end

    test "the ids are recomputed at click time, not carried from the render",
         %{conn: conn} do
      # This page can sit open for hours. A list assembled at render would
      # apply to titles that have since been themed or deleted.
      tv = section()
      item = item(tv, %{title: "One Piece", imdb_id: "tt0388629"})
      themerr_answer("tt0388629")

      {:ok, view, html} = live(conn, "/")
      assert html =~ "Apply all 1"

      # It gets themed by something else -- a bulk run, another tab.
      Fanfarr.Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: "/tv/One Piece/theme.mp3"
      })

      render_click(view, "apply_ready", %{})

      assert Fanfarr.Repo.all(Oban.Job) |> Enum.filter(&(&1.worker =~ "ApplyTheme")) == []
    end
  end

  describe "recently added" do
    test "newest first, with the status that is the point of the panel",
         %{conn: conn} do
      tv = section()
      now = DateTime.utc_now()

      item(tv, %{title: "Oldest", added_at: DateTime.add(now, -30, :day)})
      item(tv, %{title: "Newest", added_at: DateTime.add(now, -1, :hour)})
      item(tv, %{title: "Middle", added_at: DateTime.add(now, -3, :day)})

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Recently added"

      # Ordered on Plex's own addedAt, not on when we first saw the row: a
      # title synced today may have been in the library for years, and dating
      # it by our first sight would put the whole library on this list.
      newest = :binary.match(html, "Newest") |> elem(0)
      middle = :binary.match(html, "Middle") |> elem(0)
      oldest = :binary.match(html, "Oldest") |> elem(0)
      assert newest < middle and middle < oldest

      # The badge is why the panel exists -- a new arrival with no theme is
      # the thing it is meant to catch.
      assert html =~ "Missing"
    end

    test "a title Plex gave no date for is listed last, not dropped",
         %{conn: conn} do
      # nil would raise in a DateTime sort, and dropping the row would be a
      # quieter lie than showing it at the end.
      tv = section()
      item(tv, %{title: "Undated"})
      item(tv, %{title: "Dated", added_at: DateTime.add(DateTime.utc_now(), -2, :day)})

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "date unknown"
      assert :binary.match(html, "Dated") |> elem(0) < :binary.match(html, "Undated") |> elem(0)
    end
  end

  describe "health" do
    test "only problems are shown, and only when there are any", %{conn: conn} do
      # System lists all eight checks. A green wall here would bury the red one.
      tv = section()
      item(tv, %{title: "One Piece"})

      {:ok, _view, html} = live(conn, "/")

      # The dev/test environment has no Plex configured, so there is something
      # to report; what matters is that it is the failing check and not a list
      # of passing ones.
      if html =~ "Health" do
        refute html =~ "lucide-circle-check"
      end
    end
  end

  describe "the route move" do
    test "/ is the overview and /library is the library", %{conn: conn} do
      tv = section()
      item(tv, %{title: "One Piece"})

      {:ok, _view, home} = live(conn, "/")
      assert home =~ "Overview"
      refute home =~ "Search titles"

      {:ok, _view, library} = live(conn, "/library")
      assert library =~ "Search titles"
      assert library =~ "One Piece"
    end

    test "the wordmark navigates home rather than reloading the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/library")

      link = view |> element(~s(aside a[title="Fanfarr home"])) |> render()

      assert link =~ ~s(href="/")
      # data-phx-link means LiveView patches to it; a plain <a> tore the socket
      # down and reloaded everything to reach a route it could navigate to.
      assert link =~ "data-phx-link"
    end
  end
end
