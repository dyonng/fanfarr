defmodule FanfarrWeb.FeaturesTest do
  @moduledoc "The item page's find-and-apply flow, library bulk actions, the folder browser, and System."
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    section =
      Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "101",
        section_id: section.id,
        title: "One Piece",
        year: 1999,
        kind: :show,
        imdb_id: "tt0388629",
        plex_path: "/tv/One Piece (1999)"
      })

    other =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "102",
        section_id: section.id,
        title: "Fleabag",
        year: 2016,
        kind: :show
      })

    %{section: section, item: item, other: other}
  end

  describe "finding a theme on the item page" do
    test "the search box is prefilled with what people would type", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, "/library/#{item.id}")
      assert html =~ ~s(value="One Piece 1999 opening theme")
    end

    test "searching lists results with a play and a use button", %{conn: conn, item: item} do
      expect(Fanfarr.ThemeDownloaderMock, :search, fn q, limit ->
        assert q == "one piece op"
        assert limit == 8

        {:ok,
         [
           %{
             id: "abc12345678",
             url: "https://www.youtube.com/watch?v=abc12345678",
             title: "One Piece OP 1 - We Are!",
             channel: "Toei",
             duration: 92,
             thumbnail: nil,
             view_count: 1_500_000
           }
         ]}
      end)

      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      view |> element("form#theme-search") |> render_submit(%{"q" => "one piece op"})
      html = render_async(view)

      assert html =~ "We Are!"
      assert html =~ "1:32"
      assert html =~ "1.5M views"
      assert has_element?(view, ~s(button[phx-click="preview_video"][phx-value-id="abc12345678"]))
      assert has_element?(view, ~s(button[phx-click="use_video"]))
    end

    test "playing embeds the video; using it saves the pick", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      html = render_click(view, "preview_video", %{"id" => "abc12345678"})
      assert html =~ "youtube-nocookie.com/embed/abc12345678"

      html =
        render_click(view, "use_video", %{
          "url" => "https://www.youtube.com/watch?v=abc12345678",
          "title" => "We Are!"
        })

      assert html =~ "We Are!"
      assert html =~ "Outranks ThemerrDB"
      refute html =~ "youtube-nocookie.com/embed", "the preview closes once picked"

      assert Fanfarr.Library.get_media_item!(item.id).manual_theme_url =~ "abc12345678"
    end

    test "a pasted URL must be YouTube", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      view |> element("form#theme-url") |> render_submit(%{"url" => "https://evil.example/x"})
      assert Fanfarr.Library.get_media_item!(item.id).manual_theme_url == nil
      assert render(view) =~ "not a YouTube URL"

      view
      |> element("form#theme-url")
      |> render_submit(%{"url" => "https://youtu.be/abc12345678"})

      assert Fanfarr.Library.get_media_item!(item.id).manual_theme_url ==
               "https://youtu.be/abc12345678"
    end

    test "when search is unavailable the page says why", %{conn: conn, item: item} do
      expect(Fanfarr.ThemeDownloaderMock, :search, fn _, _ -> {:error, :not_installed} end)
      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      view |> element("form#theme-search") |> render_submit(%{"q" => "x"})
      assert render_async(view) =~ "yt-dlp is not installed"
    end

    test "preview and apply queue the worker with the right dry-run flag", %{
      conn: conn,
      item: item
    } do
      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      render_click(view, "preview", %{})
      render_click(view, "apply", %{})

      jobs = Fanfarr.Repo.all(Oban.Job) |> Enum.filter(&(&1.worker =~ "ApplyTheme"))
      assert Enum.map(jobs, & &1.args["dry_run"]) |> Enum.sort() == [false, true]
      assert Enum.all?(jobs, &(&1.args["media_item_id"] == item.id))
    end

    test "the apply button is disabled for a movie, with the reason", %{
      conn: conn,
      section: section
    } do
      movie =
        Fanfarr.Library.sync_media_item_from_plex!(%{
          plex_rating_key: "m1",
          section_id: section.id,
          title: "Heat",
          kind: :movie
        })

      {:ok, view, html} = live(conn, "/library/#{movie.id}")

      assert has_element?(view, ~s(button[phx-click="apply"][disabled]))
      assert html =~ "disabled until local theme files for movies are verified"
    end
  end

  describe "library bulk actions" do
    test "select the page, then act on the selection", %{conn: conn, item: item, other: other} do
      {:ok, view, _html} = live(conn, "/")

      refute has_element?(view, "#bulk-bar")
      html = render_click(view, "select_page", %{})
      assert html =~ "2 selected"

      render_click(view, "bulk", %{"action" => "preview"})

      jobs = Fanfarr.Repo.all(Oban.Job) |> Enum.filter(&(&1.worker =~ "ApplyTheme"))

      assert Enum.map(jobs, & &1.args["media_item_id"]) |> Enum.sort() ==
               Enum.sort([item.id, other.id])

      assert Enum.all?(jobs, & &1.args["dry_run"])
      refute has_element?(view, "#bulk-bar"), "selection clears after acting"
    end

    test "select all matching reaches beyond the current page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?q=flea")
      render_click(view, "toggle_select", %{"id" => "x"})
      html = render_click(view, "select_all_matching", %{})
      assert html =~ "1 selected"
    end

    test "rows show a poster", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(src="/posters/#{item.id}")
    end
  end

  describe "settings folder browser" do
    setup :register_and_log_in_user

    test "browses directories and fills the path field", %{conn: conn} do
      root = Path.join(System.tmp_dir!(), "fanfarr-fbl-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "tv1"))
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, view, _html} = live(conn, "/settings")

      html = render_click(view, "browse", %{"path" => root})
      assert html =~ "Choose a folder"
      assert html =~ "tv1"

      html = render_click(view, "browse", %{"path" => Path.join(root, "tv1")})
      assert html =~ Path.join(root, "tv1")

      html = render_click(view, "pick_folder", %{"path" => Path.join(root, "tv1")})
      refute html =~ "Choose a folder"
      assert html =~ ~s(value="#{Path.join(root, "tv1")}")
    end

    test "an unreadable path is reported inside the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")
      html = render_click(view, "browse", %{"path" => "/definitely/not/here"})
      assert html =~ "Cannot read"
    end
  end

  describe "system page" do
    test "runs the checks and lists them with the version", %{conn: conn} do
      stub(Fanfarr.ThemeDownloaderMock, :version, fn -> {:ok, "2026.08.01"} end)
      Req.Test.set_req_test_to_shared(%{})
      Req.Test.stub(Fanfarr.PlexReq, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      {:ok, view, _html} = live(conn, "/system")
      # The monitor is one process for the whole suite and may hold an older
      # snapshot from another test; ask for a fresh one explicitly.
      render_click(view, "refresh", %{})
      html = render_async(view, 10_000)

      assert html =~ "yt-dlp 2026.08.01"
      assert html =~ "Not configured"
      assert html =~ "SQLite, WAL mode"
      assert html =~ Fanfarr.Version.display()
      assert page_title(view) == "Fanfarr - System"
    end
  end
end
