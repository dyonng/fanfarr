defmodule FanfarrWeb.ThemeControllerTest do
  use FanfarrWeb.ConnCase, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-theme-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "One Pace",
        kind: :show
      })

    %{item: item, dir: dir}
  end

  test "streams the written file as audio", %{conn: conn, item: item, dir: dir} do
    path = Path.join(dir, "theme.mp3")
    File.write!(path, "ID3-and-some-audio")

    item =
      Fanfarr.Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: path
      })

    conn = get(conn, ~p"/library/#{item.id}/theme")

    assert response(conn, 200) == "ID3-and-some-audio"
    assert response_content_type(conn, :mpeg) =~ "audio/mpeg"
    # The path stays the same when a theme is replaced, so it must not cache.
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  describe "range requests" do
    setup %{item: item, dir: dir} do
      path = Path.join(dir, "theme.mp3")
      File.write!(path, "0123456789")

      item =
        Fanfarr.Library.record_local_theme!(item, %{
          local_theme_present: true,
          local_theme_path: path
        })

      %{item: item}
    end

    test "a full request advertises that ranges are supported", %{conn: conn, item: item} do
      conn = get(conn, ~p"/library/#{item.id}/theme")

      assert response(conn, 200) == "0123456789"
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "serves the requested slice", %{conn: conn, item: item} do
      conn =
        conn
        |> put_req_header("range", "bytes=2-5")
        |> get(~p"/library/#{item.id}/theme")

      assert response(conn, 206) == "2345"
      assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
    end

    test "an open-ended range runs to the end", %{conn: conn, item: item} do
      conn =
        conn |> put_req_header("range", "bytes=7-") |> get(~p"/library/#{item.id}/theme")

      assert response(conn, 206) == "789"
      assert get_resp_header(conn, "content-range") == ["bytes 7-9/10"]
    end

    test "a suffix range counts back from the end", %{conn: conn, item: item} do
      conn =
        conn |> put_req_header("range", "bytes=-3") |> get(~p"/library/#{item.id}/theme")

      assert response(conn, 206) == "789"
    end

    test "a range past the end is refused, not silently clamped", %{conn: conn, item: item} do
      conn =
        conn |> put_req_header("range", "bytes=50-60") |> get(~p"/library/#{item.id}/theme")

      assert response(conn, 416)
      assert get_resp_header(conn, "content-range") == ["bytes */10"]
    end

    test "an unparseable range falls back to the whole file", %{conn: conn, item: item} do
      conn =
        conn |> put_req_header("range", "bytes=nonsense") |> get(~p"/library/#{item.id}/theme")

      assert response(conn, 200) == "0123456789"
    end
  end

  test "404 when no theme has been written", %{conn: conn, item: item} do
    assert conn |> get(~p"/library/#{item.id}/theme") |> response(404)
  end

  test "404 when the recorded file has since been deleted", %{conn: conn, item: item, dir: dir} do
    path = Path.join(dir, "gone.mp3")
    File.write!(path, "x")

    item =
      Fanfarr.Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: path
      })

    File.rm!(path)

    assert conn |> get(~p"/library/#{item.id}/theme") |> response(404)
  end

  test "requires a login once an operator account exists", %{conn: conn, item: item, dir: dir} do
    path = Path.join(dir, "theme.mp3")
    File.write!(path, "x")

    item =
      Fanfarr.Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: path
      })

    Fanfarr.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      username: "operator",
      password: "a-long-password",
      password_confirmation: "a-long-password"
    })
    |> Ash.create!(authorize?: false)

    assert conn |> get(~p"/library/#{item.id}/theme") |> response(401)
  end

  describe "the local-address bypass" do
    setup %{item: item, dir: dir} do
      path = Path.join(dir, "theme.mp3")
      File.write!(path, "x")

      item =
        Fanfarr.Library.record_local_theme!(item, %{
          local_theme_present: true,
          local_theme_path: path
        })

      Fanfarr.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        username: "operator",
        password: "a-long-password",
        password_confirmation: "a-long-password"
      })
      |> Ash.create!(authorize?: false)

      %{item: item}
    end

    test "lets a local request through once enabled, with no session at all", %{
      conn: conn,
      item: item
    } do
      Fanfarr.Accounts.AuthMode.set_bypass_enabled(true)

      # Phoenix.ConnTest's default conn has remote_ip 127.0.0.1 -- a genuine
      # local address, not a spoofed header.
      assert conn |> get(~p"/library/#{item.id}/theme") |> response(200)
    end

    test "still requires a login from a non-local address", %{conn: conn, item: item} do
      Fanfarr.Accounts.AuthMode.set_bypass_enabled(true)

      conn = %{conn | remote_ip: {8, 8, 8, 8}}
      assert conn |> get(~p"/library/#{item.id}/theme") |> response(401)
    end

    test "a local request still requires a login when the setting is off", %{
      conn: conn,
      item: item
    } do
      assert conn |> get(~p"/library/#{item.id}/theme") |> response(401)
    end
  end
end
