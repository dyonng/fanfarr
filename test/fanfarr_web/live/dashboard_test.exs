defmodule FanfarrWeb.DashboardTest do
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  describe "authentication" do
    test "the dashboard requires sign-in once an operator account exists", %{conn: conn} do
      Fanfarr.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        username: "operator",
        password: "a-long-password",
        password_confirmation: "a-long-password"
      })
      |> Ash.create!(authorize?: false)

      for path <- ["/", "/activity", "/settings"] do
        assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, path)
      end
    end

    test "with no operator account the sign-in page redirects to the dashboard",
         %{conn: conn} do
      # Authentication is optional. A form asking for credentials that were
      # never configured is a dead end, so it should not be reachable.
      refute Fanfarr.Accounts.AuthMode.required?()

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/sign-in")
    end

    test "with no operator account the dashboard is open", %{conn: conn} do
      # AUTH_USERNAME/AUTH_PASSWORD unset means no account, which means no
      # login -- the way Sonarr and Radarr start. Redirecting to a form nobody
      # has credentials for would lock the dashboard rather than open it.
      refute Fanfarr.Accounts.AuthMode.required?()

      assert {:ok, _view, html} = live(conn, "/")
      assert html =~ "Library"
    end

    test "there is no registration route" do
      # Credentials come from the environment; a sign-up form would be a
      # second, unguarded way to create an account.
      assert :error =
               Phoenix.Router.route_info(FanfarrWeb.Router, "GET", "/register", "example.com")

      assert :error = Phoenix.Router.route_info(FanfarrWeb.Router, "GET", "/reset", "example.com")
    end

    test "the local-address bypass opens the dashboard with no session at all", %{conn: conn} do
      Fanfarr.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        username: "operator",
        password: "a-long-password",
        password_confirmation: "a-long-password"
      })
      |> Ash.create!(authorize?: false)

      Fanfarr.Accounts.AuthMode.set_bypass_enabled(true)

      # Phoenix.ConnTest's default conn has remote_ip 127.0.0.1.
      for path <- ["/", "/activity", "/settings"] do
        assert {:ok, _view, _html} = live(conn, path)
      end
    end

    test "the local-address bypass does not apply from a non-local address", %{conn: conn} do
      Fanfarr.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        username: "operator",
        password: "a-long-password",
        password_confirmation: "a-long-password"
      })
      |> Ash.create!(authorize?: false)

      Fanfarr.Accounts.AuthMode.set_bypass_enabled(true)

      conn = %{conn | remote_ip: {8, 8, 8, 8}}
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/")
    end
  end

  describe "page titles" do
    test "every page is prefixed with the product name", %{conn: conn} do
      for {path, title} <- [
            {"/", "Library"},
            {"/activity", "Activity"},
            {"/settings", "Settings"},
            {"/logs", "Logs"}
          ] do
        {:ok, view, _html} = live(conn, path)
        assert page_title(view) == "Fanfarr - #{title}"
      end
    end
  end

  describe "library" do
    setup :register_and_log_in_user

    setup do
      section =
        Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

      item = fn attrs ->
        Fanfarr.Library.MediaItem
        |> Ash.Changeset.for_create(
          :create,
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
        |> Ash.create!()
      end

      item.(%{title: "One Piece", year: 1999})

      item.(%{
        title: "Fleabag",
        year: 2016,
        plex_theme_url: "/library/metadata/2/theme/1",
        plex_theme_origin: :plex_agent,
        plex_theme_agent: "tv.plex.agents.series"
      })

      %{section: section, item: item}
    end

    test "lists items with their status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "One Piece"
      assert html =~ "Fleabag"
      # One item has nothing, the other has a Plex-supplied theme.
      assert html =~ "Missing"
      assert html =~ "Plex"
      assert html =~ "1 without a theme"
    end

    test "the status filter narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?status=missing")

      html = render(view)
      assert html =~ "One Piece"
      refute html =~ "Fleabag"
    end

    test "search narrows by title", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?q=flea")

      html = render(view)
      assert html =~ "Fleabag"
      refute html =~ "One Piece"
    end

    # The order titles appear in the rendered table.
    defp order(html) do
      Regex.scan(~r/(One Piece|Fleabag|Unrated Thing)/, html)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()
    end

    test "scores from different services are shown on the same scale", %{
      conn: conn,
      item: item
    } do
      item.(%{
        title: "Rated Show",
        critic_score: 8.7,
        critic_score_source: "rottentomatoes",
        audience_score: 7.2,
        audience_score_source: "imdb"
      })

      {:ok, _view, html} = live(conn, "/")

      # Both as percentages, though one came from Rotten Tomatoes and the
      # other from IMDb. A column mixing 87% with 7.2 read as unsorted.
      assert html =~ "87%"
      assert html =~ "72%"
      refute html =~ ">7.2<"

      # The service and its own scale stay available on hover.
      assert html =~ "IMDb"
      assert html =~ "7.2/10"
    end

    test "an item with no rating shows nothing rather than a nought", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "—"
      refute html =~ ">0%<"
    end

    test "clicking a column header sorts by it, and again reverses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?sort=year")
      assert order(render(view)) == ["One Piece", "Fleabag"]

      {:ok, view, _html} = live(conn, "/?sort=-year")
      assert order(render(view)) == ["Fleabag", "One Piece"]
    end

    test "sorting by score puts the unrated last, not first", %{conn: conn, item: item} do
      # Two rated items around one unrated, so "last" means something.
      item.(%{title: "Unrated Thing", critic_score: nil})
      set_score("One Piece", 9.0)
      set_score("Fleabag", 6.0)

      # Ascending would otherwise lead with every item that has no score,
      # burying the low ones actually being looked for.
      {:ok, view, _html} = live(conn, "/?sort=critic")
      assert order(render(view)) == ["Fleabag", "One Piece", "Unrated Thing"]

      {:ok, view, _html} = live(conn, "/?sort=-critic")
      assert order(render(view)) == ["One Piece", "Fleabag", "Unrated Thing"]
    end

    defp set_score(title, score) do
      Fanfarr.Library.list_media_items!()
      |> Enum.find(&(&1.title == title))
      |> Ash.Changeset.for_update(:update, %{critic_score: score})
      |> Ash.update!()
    end

    test "sorting keeps the filters, and filtering keeps the sort", %{conn: conn} do
      {:ok, view, html} = live(conn, "/?q=one&sort=-year")

      # The header links carry the search along rather than dropping it.
      assert html =~ "q=one"
      assert order(render(view)) == ["One Piece"]
    end

    test "an unknown sort is ignored rather than crashing the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/?sort=havoc")

      assert html =~ "One Piece"
    end

    test "opening an item carries the view it was opened from", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?status=missing&sort=-year&q=one&page=1")

      # The link out has to carry the filters, or the item page has nothing to
      # send the reader back to.
      assert view
             |> element("a", "One Piece")
             |> render() =~ "status=missing"
    end

    test "an item's Library link returns to the filtered view", %{conn: conn} do
      [item | _] = Fanfarr.Library.list_media_items!()

      {:ok, view, _html} = live(conn, "/library/#{item.id}?status=missing&q=one&sort=-year")

      assert view |> element("a", "← Library") |> render() =~ "status=missing"

      # And following it actually lands on that view rather than page one of
      # everything.
      {:ok, _library, html} =
        view |> element("a", "← Library") |> render_click() |> follow_redirect(conn)

      assert html =~ "One Piece"
      refute html =~ "Fleabag"
    end

    test "page one is left off the link rather than spelled out", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?status=missing")

      link = view |> element("a", "One Piece") |> render()

      assert link =~ "status=missing"
      refute link =~ "page="
    end

    test "returning lands on the page the item was opened from", %{conn: conn, item: item} do
      # A page past the first, which is exactly where losing your place hurts.
      for n <- 1..60, do: item.(%{title: "Filler #{String.pad_leading("#{n}", 3, "0")}"})

      {:ok, view, _html} = live(conn, "/?page=2")
      link = view |> element("a", "One Piece") |> render()
      assert link =~ "page=2"

      {:ok, item_view, _html} = live(conn, "/library/#{first_item_id()}?page=2")
      assert item_view |> element("a", "← Library") |> render() =~ "page=2"
    end

    defp first_item_id do
      Fanfarr.Library.list_media_items!() |> List.first() |> Map.fetch!(:id)
    end

    test "an item reached without that context just goes to the library", %{conn: conn} do
      # From Activity, a bookmark, or a shared link.
      [item | _] = Fanfarr.Library.list_media_items!()

      {:ok, view, _html} = live(conn, "/library/#{item.id}")

      assert view |> element("a", "← Library") |> render() =~ ~s(href="/")
    end

    test "the return link cannot be pointed somewhere else", %{conn: conn} do
      [item | _] = Fanfarr.Library.list_media_items!()

      {:ok, view, _html} =
        live(conn, "/library/#{item.id}?status=missing&next=https://evil.example")

      link = view |> element("a", "← Library") |> render()

      # Only the known filter keys are reassembled, and only onto "/".
      assert link =~ "status=missing"
      refute link =~ "evil.example"
    end

    test "an item Plex has stopped listing is not in the table", %{conn: conn} do
      Fanfarr.Library.list_media_items!()
      |> Enum.find(&(&1.title == "Fleabag"))
      |> Fanfarr.Library.mark_media_item_missing!()

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "One Piece"
      refute html =~ "Fleabag"
    end

    test "its own page still opens, and says why it is not in the library", %{conn: conn} do
      # A link from Activity, or the theme history, or a bookmark. The row is
      # kept precisely so those do not break; it just should not pretend the
      # item is still there.
      item =
        Fanfarr.Library.list_media_items!()
        |> Enum.find(&(&1.title == "Fleabag"))
        |> Fanfarr.Library.mark_media_item_missing!()

      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      assert html =~ "Fleabag"
      assert html =~ "Plex no longer lists this item"
    end

    test "an item page shows its history section", %{conn: conn} do
      [item | _] = Fanfarr.Library.list_media_items!()
      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      assert html =~ item.title
      assert html =~ "History"
      assert html =~ "cannot be undone"
    end

    test "an item page names a stock Plex theme rather than just saying yes",
         %{conn: conn} do
      item = Enum.find(Fanfarr.Library.list_media_items!(), &(&1.title == "Fleabag"))
      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      # "yes" would hide the distinction the whole product turns on.
      assert html =~ "Plex default"
      assert html =~ "tv.plex.agents.series"
    end

    test "an item page says none when there is no theme at all", %{conn: conn} do
      item = Enum.find(Fanfarr.Library.list_media_items!(), &(&1.title == "One Piece"))
      {:ok, _view, html} = live(conn, "/library/#{item.id}")

      assert html =~ "Theme on server"
      refute html =~ "Plex default"
    end
  end

  describe "settings" do
    setup :register_and_log_in_user
    # The connection probe runs in a Task, not the test process, so the mock
    # must be reachable globally. The module is async: false for this reason.
    setup :set_mox_global
    setup :verify_on_exit!

    test "saving the Plex connection stores overrides", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#plex-form")
      |> render_submit(%{"plex_url" => "http://plex.local:32400", "plex_token" => "tok123"})

      assert Fanfarr.Config.get("plex_url") == "http://plex.local:32400"
      assert Fanfarr.Config.get("plex_token") == "tok123"
    end

    test "an empty token field keeps the stored token", %{conn: conn} do
      Fanfarr.Settings.put_setting!("plex_token", "keep-me")
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#plex-form")
      |> render_submit(%{"plex_url" => "http://plex.local:32400", "plex_token" => ""})

      assert Fanfarr.Config.get("plex_token") == "keep-me"
    end

    test "a URL typed without a scheme is stored with one", %{conn: conn} do
      # "192.168.1.121:32400" is what people type. Req raises on it, which took
      # the LiveView process down and looked like the page reloading.
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#plex-form")
      |> render_submit(%{"plex_url" => "192.168.1.121:32400/", "plex_token" => "t"})

      assert Fanfarr.Config.get("plex_url") == "http://192.168.1.121:32400"
    end

    test "testing the connection uses what is typed, without saving it", %{conn: conn} do
      expect(Fanfarr.PlexClientMock, :server_info, fn config ->
        assert config.base_url == "http://typed.local:32400"
        assert config.token == "typed-token"
        # The interactive probe must not wait 30s with retries.
        assert config.req_options[:retry] == false
        {:ok, %{name: "Serve The DY", version: "1.43.4"}}
      end)

      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#plex-form")
      |> render_submit(%{
        "plex_url" => "typed.local:32400",
        "plex_token" => "typed-token",
        "intent" => "test"
      })

      html = render_async(view)
      assert html =~ "Connected to Serve The DY"
      assert Fanfarr.Config.get("plex_url") == nil, "testing must not save"
    end

    test "a connection failure is reported, not crashed on", %{conn: conn} do
      expect(Fanfarr.PlexClientMock, :server_info, fn _ ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#plex-form")
      |> render_submit(%{"plex_url" => "http://x:1", "plex_token" => "t", "intent" => "test"})

      assert render_async(view) =~ "connection refused"
    end

    test "testing with no token anywhere says so instead of probing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html =
        view
        |> element("form#plex-form")
        |> render_submit(%{"plex_url" => "http://x:1", "plex_token" => "", "intent" => "test"})

      assert html =~ "Enter a token first"
    end

    test "root folders can be added and are health-checked on the spot", %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "fanfarr-rf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form[phx-submit=add_root_folder]")
      |> render_submit(%{"path" => dir, "label" => "test drive", "kind" => "show"})

      [rf] = Fanfarr.Library.list_root_folders!()
      assert rf.path == dir
      assert rf.accessible
      assert render(view) =~ "accessible"
    end

    test "a root folder can be removed with no confirmation to click through", %{conn: conn} do
      rf =
        Fanfarr.Library.create_root_folder!(%{path: "/tv1", label: "", kind: :show})

      {:ok, view, html} = live(conn, "/settings")
      refute html =~ "data-confirm"

      view |> element(~s(button[phx-value-id="#{rf.id}"])) |> render_click()

      assert Fanfarr.Library.list_root_folders!() == []
    end

    test "toggling a library flips enabled", %{conn: conn} do
      s = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "9", title: "Anime", kind: :show})
      {:ok, view, _html} = live(conn, "/settings")

      view |> element(~s(button[phx-value-id="#{s.id}"])) |> render_click()
      assert Fanfarr.Library.get_section!(s.id).enabled == true
    end

    test "toggling the local-address bypass persists it", %{conn: conn} do
      refute Fanfarr.Accounts.AuthMode.bypass_enabled?()
      {:ok, view, html} = live(conn, "/settings")
      assert html =~ "Disabled"

      view |> element("button", "Disabled") |> render_click()

      assert Fanfarr.Accounts.AuthMode.bypass_enabled?()
      assert render(view) =~ "Enabled"
    end

    test "saving a yt-dlp proxy stores an override", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#ytdlp-proxy-form")
      |> render_submit(%{"ytdlp_proxy" => "socks5://127.0.0.1:1080"})

      assert Fanfarr.Config.get("ytdlp_proxy") == "socks5://127.0.0.1:1080"
    end

    test "saving a loudness target stores an override", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#loudness-form")
      |> render_submit(%{"theme_loudness_lufs" => "-16"})

      assert Fanfarr.Config.get("theme_loudness_lufs") == "-16.0"
      assert Fanfarr.Themes.Normalizer.target() == -16.0
    end

    test "a non-numeric loudness target is rejected, not stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html =
        view
        |> element("form#loudness-form")
        |> render_submit(%{"theme_loudness_lufs" => "loud please"})

      assert html =~ "Enter a negative number"
      assert Fanfarr.Config.get("theme_loudness_lufs") == nil
    end

    test "blanking the loudness target resets it to the default", %{conn: conn} do
      Fanfarr.Settings.put_setting!("theme_loudness_lufs", "-16.0")
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form#loudness-form")
      |> render_submit(%{"theme_loudness_lufs" => ""})

      assert Fanfarr.Config.get("theme_loudness_lufs") == nil
      assert Fanfarr.Themes.Normalizer.target() == -14.0
    end
  end
end
