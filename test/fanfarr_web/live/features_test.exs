defmodule FanfarrWeb.FeaturesTest do
  @moduledoc "The item page's find-and-apply flow, library bulk actions, the folder browser, and System."
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Ecto.Query, only: [from: 2]

  # The page re-asks on a timer, so the assertion has to outlast one tick.
  defp eventually(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(check, attempts - 1)
    end
  end

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

      # The embed URL is YouTube's iframe API to build, not ours: the server
      # hands over the id and the volume controls the API makes possible.
      assert html =~ ~s(data-video-id="abc12345678")
      assert html =~ ~s(aria-label="Volume")

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

    test "a movie can be applied like anything else", %{
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

      refute has_element?(view, ~s(button[phx-click="apply"][disabled]))
      assert html =~ "movie agent supplies no themes of its own"
    end
  end

  describe "the queue widget and the activity page" do
    test "applying no longer stops to ask", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, "/library/#{item.id}")
      refute html =~ "data-confirm"
    end

    test "a queued job shows in the corner of another page, linking to Activity",
         %{conn: conn, item: item} do
      {:ok, _job} =
        %{media_item_id: item.id, dry_run: false}
        |> Fanfarr.Workers.ApplyTheme.new()
        |> Oban.insert()

      {:ok, view, _html} = live(conn, "/settings")

      assert has_element?(view, ~s(a[href="/activity"]), "queued")
    end

    test "the widget stays out of the way when nothing is queued", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")
      refute has_element?(view, ~s(a[href="/activity"]), "queued")
    end

    test "Activity itself does not show the widget", %{conn: conn, item: item} do
      {:ok, _job} =
        %{media_item_id: item.id} |> Fanfarr.Workers.ApplyTheme.new() |> Oban.insert()

      {:ok, view, _html} = live(conn, "/activity")

      refute has_element?(view, ~s(a.fixed[href="/activity"]))
    end

    test "the queue names the title in its own column, linked to the item",
         %{conn: conn, item: item} do
      {:ok, _job} =
        %{media_item_id: item.id, dry_run: false}
        |> Fanfarr.Workers.ApplyTheme.new()
        |> Oban.insert()

      {:ok, view, html} = live(conn, "/activity")

      assert html =~ "Apply theme"
      assert html =~ "background, so you can leave this page"

      # Its own cell, and a way through to the item rather than a dead string.
      assert has_element?(view, ~s(a[href="/library/#{item.id}"]), "One Piece")
    end

    test "a job for an item that has since been deleted still renders", %{conn: conn} do
      {:ok, _job} =
        %{media_item_id: Ash.UUID.generate(), dry_run: false}
        |> Fanfarr.Workers.ApplyTheme.new()
        |> Oban.insert()

      {:ok, _view, html} = live(conn, "/activity")
      assert html =~ "removed item"
    end
  end

  describe "the in-flight card clearing itself" do
    test "it goes away once the job leaves the queue, with no further broadcast",
         %{conn: conn, item: item} do
      # Exactly the shape that left it up for ten minutes: a job still marked
      # executing when the page reloads, because the worker broadcasts from
      # inside perform/1 and then carries on talking to Plex. No second
      # broadcast ever comes, so the page has to re-ask.
      {:ok, job} =
        %{media_item_id: item.id, dry_run: false}
        |> Fanfarr.Workers.ApplyTheme.new()
        |> Oban.insert()

      {:ok, view, html} = live(conn, "/library/#{item.id}")
      assert html =~ "Working on this item"

      # The job finishes. Nothing tells the page.
      Fanfarr.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "completed"]
      )

      assert html =~ "Working on this item"

      # The poll is what gets it back, unaided.
      assert eventually(fn -> render(view) =~ "Apply theme" end)
      refute render(view) =~ "Working on this item"
    end
  end

  describe "feedback while a theme is being applied" do
    test "clicking apply immediately shows work in progress", %{conn: conn, item: item} do
      {:ok, view, html} = live(conn, "/library/#{item.id}")

      refute html =~ "Working on this item"

      html = render_click(view, "apply", %{})

      # The click has to visibly do something. On a busy queue the worker may
      # not start for minutes, so this cannot wait for the worker to say so.
      assert html =~ "Working on this item"
      assert html =~ "Working…"
      assert has_element?(view, ~s(button[phx-click="apply"][disabled]))
      assert has_element?(view, ~s(button[phx-click="preview"][disabled]))
    end

    test "a queued job is still reflected after a reload", %{conn: conn, item: item} do
      {:ok, _} = Fanfarr.Workers.ApplyTheme.enqueue(item, dry_run: false)

      {:ok, _view, html} = live(conn, "/library/#{item.id}")
      assert html =~ "Working on this item"
    end

    test "no in-flight state once nothing is queued", %{conn: conn, item: item} do
      {:ok, job} = Fanfarr.Workers.ApplyTheme.enqueue(item, dry_run: false)
      Fanfarr.Repo.delete!(job)

      {:ok, _view, html} = live(conn, "/library/#{item.id}")
      refute html =~ "Working on this item"
    end
  end

  defp lookup_jobs do
    Oban.Job
    |> Fanfarr.Repo.all()
    |> Enum.filter(&(&1.worker =~ "LookupTheme"))
  end

  describe "ThemerrDB on the item page" do
    test "opening an item asks ThemerrDB about it", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      assert html =~ "Asking ThemerrDB about this title"

      assert [job] = lookup_jobs()
      assert job.args["media_item_id"] == item.id
    end

    test "an item Plex gave no ids for says so instead of queueing a hopeless lookup",
         %{conn: conn, other: other} do
      {:ok, _view, html} = live(conn, "/library/#{other.id}")

      assert html =~ "ThemerrDB is keyed on those"
      assert lookup_jobs() == []
    end

    test "an answer already on file is shown without asking again",
         %{conn: conn, item: item} do
      {:ok, _entry} =
        Fanfarr.Themes.record_themerr_lookup(%{
          item_type: :tv_shows,
          database: :imdb,
          external_id: item.imdb_id,
          found: true,
          youtube_theme_url: "https://www.youtube.com/watch?v=abc12345678"
        })

      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      assert html =~ "youtube.com/watch?v=abc12345678"
      assert lookup_jobs() == []
    end

    test "the suggestion can be pinned as the item's pick", %{conn: conn, item: item} do
      {:ok, _entry} =
        Fanfarr.Themes.record_themerr_lookup(%{
          item_type: :tv_shows,
          database: :imdb,
          external_id: item.imdb_id,
          found: true,
          youtube_theme_url: "https://www.youtube.com/watch?v=abc12345678"
        })

      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      html = view |> element("button[phx-click=use_themerr]") |> render_click()

      assert html =~ "ThemerrDB suggestion"

      assert Fanfarr.Library.get_media_item!(item.id).manual_theme_url ==
               "https://www.youtube.com/watch?v=abc12345678"
    end

    test "a title ThemerrDB knows but has no theme for is not left ambiguous",
         %{conn: conn, item: item} do
      {:ok, _entry} =
        Fanfarr.Themes.record_themerr_lookup(%{
          item_type: :tv_shows,
          database: :imdb,
          external_id: item.imdb_id,
          found: true,
          youtube_theme_url: nil
        })

      {:ok, _view, html} = live(conn, "/library/#{item.id}")
      assert html =~ "has no theme for it"
    end
  end

  describe "listening to what was written" do
    setup %{item: item} do
      dir = Path.join(System.tmp_dir!(), "fanfarr-play-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "theme.mp3")
      File.write!(path, "audio")

      item =
        Fanfarr.Library.record_local_theme!(item, %{
          local_theme_present: true,
          local_theme_path: path
        })

      %{item: item, path: path}
    end

    test "a newly written theme changes the player's key so it reloads",
         %{conn: conn, item: item, path: path} do
      {:ok, view, html} = live(conn, "/library/#{item.id}")
      [_, first] = Regex.run(~r/theme-player-(\d+)/, html)

      # What the worker does on success, in the order it does it: the local
      # theme is recorded before the broadcast, or a subscriber reloads with
      # the previous file's timestamp and the player keeps the old audio.
      File.write!(path, "different audio")

      Fanfarr.Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: path
      })

      Phoenix.PubSub.broadcast(Fanfarr.PubSub, "item:#{item.id}", {:item_updated, item.id})

      html = render(view)
      [_, second] = Regex.run(~r/theme-player-(\d+)/, html)

      refute first == second, "the player must be replaced when the file changes"
    end

    test "the page offers a player for the file it wrote", %{conn: conn, item: item, path: path} do
      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      assert html =~ "The file Fanfarr wrote"
      assert html =~ path
      assert html =~ "/library/#{item.id}/theme?v="
      assert html =~ "theme-player-"
      assert html =~ "Listen before trusting it"
    end

    test "a refresh that Plex ignores says so instead of implying success",
         %{conn: conn, item: item} do
      # The failure the operator actually hits: the file is on disk, Plex is
      # told to look again, and Plex goes on serving its own agent's theme.
      agent_key = "metadata://themes/tv.plex.agents.series_b008372"

      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k ->
        {:ok, %{"theme" => "/library/metadata/101/theme/17"}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k ->
        {:ok,
         [
           %{
             rating_key: agent_key,
             key: "/library/metadata/101/file",
             selected: true,
             origin: :plex_agent,
             agent: "tv.plex.agents.series"
           }
         ]}
      end)

      # The item's folder, in Plex's own view, and the section it belongs to.
      expect(Fanfarr.PlexClientMock, :scan_directory, fn _c, "1", "/tv/One Piece (1999)" ->
        :ok
      end)

      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _config, rating_key ->
        assert rating_key == item.plex_rating_key
        :ok
      end)

      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      {:ok, view, _html} = live(conn, "/library/#{item.id}")
      render_click(view, "refresh_plex", %{})

      html = render_async(view, 10_000)

      assert html =~ "What Plex serves now"
      assert html =~ "Plex accepted the scan request"
      assert html =~ "serving a theme from its own agent"
      assert html =~ "tv.plex.agents.series"
      # The ratingKey is shown verbatim: it is the evidence for the verdict.
      assert html =~ agent_key

      # And what was read is stored, so the badge stops disagreeing with it.
      reloaded = Fanfarr.Library.get_media_item!(item.id)
      assert reloaded.plex_theme_origin == :plex_agent
      assert reloaded.plex_theme_agent == "tv.plex.agents.series"
    end

    test "a theme Plex does not attribute to an agent reads as the local file taking",
         %{conn: conn, item: item} do
      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k ->
        {:ok, %{"theme" => "/library/metadata/101/theme/17"}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k ->
        {:ok,
         [
           %{
             rating_key: "media://themes/abc",
             key: "/library/metadata/101/file",
             selected: true,
             origin: :unknown,
             agent: nil
           }
         ]}
      end)

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> :ok end)
      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> :ok end)
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      {:ok, view, _html} = live(conn, "/library/#{item.id}")
      render_click(view, "refresh_plex", %{})

      assert render_async(view, 10_000) =~ "consistent with it having picked up the local file"
    end

    test "a refusal from Plex is reported, not swallowed", %{conn: conn, item: item} do
      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k -> {:ok, []} end)
      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> :ok end)
      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> {:error, {:http, 403}} end)
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      {:ok, view, _html} = live(conn, "/library/#{item.id}")
      render_click(view, "refresh_plex", %{})

      assert render_async(view, 10_000) =~ "Plex refused the refresh"
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

  describe "system page log and diagnostics" do
    setup do
      Fanfarr.Log.Buffer.clear()
      Fanfarr.Diagnostics.Redactor.forget_all()
      stub(Fanfarr.ThemeDownloaderMock, :version, fn -> {:ok, "2026.08.01"} end)
      on_exit(fn -> Fanfarr.Diagnostics.Redactor.forget_all() end)
      :ok
    end

    test "shows captured log lines and filters them by level", %{conn: conn} do
      require Logger
      Logger.error("a distinctive error line")
      Logger.warning("a distinctive warning line")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/system")

      html = render_click(view, "refresh_logs", %{})
      assert html =~ "a distinctive error line"
      assert html =~ "a distinctive warning line"

      html = render_change(view, "set_log_level", %{"level" => "error"})
      assert html =~ "a distinctive error line"
      refute html =~ "a distinctive warning line"
    end

    test "a secret logged before the page loaded is not on the page", %{conn: conn} do
      require Logger
      Fanfarr.Settings.put_setting!("plex_token", "TOKEN-must-not-appear")
      Fanfarr.Diagnostics.Redactor.prime()
      Logger.error("requesting with X-Plex-Token=TOKEN-must-not-appear")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/system")
      html = render_click(view, "refresh_logs", %{})

      refute html =~ "TOKEN-must-not-appear"
      assert html =~ "[redacted]"
    end

    test "clearing empties the log", %{conn: conn} do
      require Logger
      Logger.error("soon to be cleared")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/system")
      html = render_click(view, "clear_logs", %{})

      refute html =~ "soon to be cleared"
    end

    test "tracing an item by title explains why it has no path", %{conn: conn, section: section} do
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "999",
        section_id: section.id,
        title: "Pathless Show",
        kind: :show,
        plex_path: nil
      })

      {:ok, view, _html} = live(conn, "/system")

      view
      |> element(~s(form[phx-submit="tool"] input[value="item"]))
      |> render()

      render_submit(view, "tool", %{"tool" => "item", "query" => "Pathless"})
      html = render_async(view, 10_000)

      assert html =~ "Pathless Show"
      assert html =~ "Plex reported no path"
    end

    test "checking a video says whether yt-dlp can download it", %{conn: conn} do
      expect(Fanfarr.ThemeDownloaderMock, :probe, fn _url ->
        {:ok, %{title: "ANGEL &amp; DEVIL", duration: 93, uploader: "GRe4N BOYZ"}}
      end)

      {:ok, view, _html} = live(conn, "/system")

      render_submit(view, "tool", %{
        "tool" => "video",
        "url" => "https://www.youtube.com/watch?v=VHxeuLf_eRs"
      })

      html = render_async(view, 10_000)
      assert html =~ "Downloadable: YES"
      assert html =~ "embedding is"
    end

    test "the Plex probe refuses a URL that is not server-relative", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")

      render_submit(view, "tool", %{"tool" => "plex", "path" => "https://evil.example/x"})
      assert render_async(view, 10_000) =~ "must start with a slash"
    end

    test "the bug-report bundle carries the version and the health results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")

      render_click(view, "tool", %{"tool" => "bundle"})
      html = render_async(view, 15_000)

      assert html =~ "Fanfarr diagnostics"
      assert html =~ "Environment"
      assert html =~ "Recent log"
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
