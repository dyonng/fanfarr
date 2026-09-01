defmodule FanfarrWeb.DashboardTest do
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

    test "saving the Plex connection stores overrides", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form[phx-submit=save_plex]")
      |> render_submit(%{"plex_url" => "http://plex.local:32400", "plex_token" => "tok123"})

      assert Fanfarr.Config.get("plex_url") == "http://plex.local:32400"
      assert Fanfarr.Config.get("plex_token") == "tok123"
    end

    test "an empty token field keeps the stored token", %{conn: conn} do
      Fanfarr.Settings.put_setting!("plex_token", "keep-me")
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("form[phx-submit=save_plex]")
      |> render_submit(%{"plex_url" => "http://plex.local:32400", "plex_token" => ""})

      assert Fanfarr.Config.get("plex_token") == "keep-me"
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

    test "toggling a library flips enabled", %{conn: conn} do
      s = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "9", title: "Anime", kind: :show})
      {:ok, view, _html} = live(conn, "/settings")

      view |> element(~s(button[phx-value-id="#{s.id}"])) |> render_click()
      assert Fanfarr.Library.get_section!(s.id).enabled == true
    end
  end
end
