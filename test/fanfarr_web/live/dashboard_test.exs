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
