defmodule FanfarrWeb.PosterControllerTest do
  use FanfarrWeb.ConnCase, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-pc-#{:erlang.unique_integer([:positive])}")
    Application.put_env(:fanfarr, :cache_dir, dir)

    on_exit(fn ->
      Application.delete_env(:fanfarr, :cache_dir)
      File.rm_rf(dir)
    end)

    Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
    Fanfarr.Settings.put_setting!("plex_token", "t")
    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "x",
        kind: :show,
        plex_thumb_key: "/library/metadata/1/thumb/1"
      })

    %{item: item}
  end

  test "serves the cached poster with a long cache lifetime", %{conn: conn, item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_image, fn _c, _k, _o -> {:ok, {"image/jpeg", "JPG"}} end)

    conn = get(conn, ~p"/posters/#{item.id}")

    assert response(conn, 200) == "JPG"
    assert response_content_type(conn, :jpeg) =~ "image/jpeg"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=604800"]
  end

  test "a missing poster is a placeholder, not a broken image", %{conn: conn, item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_image, fn _c, _k, _o -> {:error, :timeout} end)

    conn = get(conn, ~p"/posters/#{item.id}")

    assert response(conn, 200) =~ "<svg"
    assert response_content_type(conn, :svg) =~ "image/svg+xml"
  end

  test "an unknown item is a placeholder too", %{conn: conn} do
    conn = get(conn, ~p"/posters/#{Ash.UUID.generate()}")
    assert response(conn, 200) =~ "<svg"
  end

  test "requires a login once an operator account exists", %{conn: conn, item: item} do
    Fanfarr.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      username: "operator",
      password: "a-long-password",
      password_confirmation: "a-long-password"
    })
    |> Ash.create!(authorize?: false)

    conn = get(conn, ~p"/posters/#{item.id}")
    assert response(conn, 401)
  end
end
