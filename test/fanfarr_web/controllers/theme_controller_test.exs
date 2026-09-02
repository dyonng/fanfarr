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
end
