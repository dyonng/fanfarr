defmodule Fanfarr.PostersTest do
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-posters-#{:erlang.unique_integer([:positive])}")
    previous = Application.get_env(:fanfarr, :cache_dir)
    Application.put_env(:fanfarr, :cache_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fanfarr, :cache_dir, previous),
        else: Application.delete_env(:fanfarr, :cache_dir)

      File.rm_rf(dir)
    end)

    Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
    Fanfarr.Settings.put_setting!("plex_token", "t")

    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "45870",
        section_id: section.id,
        title: "OSHI NO KO",
        kind: :show,
        plex_thumb_key: "/library/metadata/45870/thumb/1788156492"
      })

    %{item: item, dir: dir}
  end

  test "fetches once and serves from disk afterwards", %{item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_image, 1, fn _config, key, _opts ->
      assert key == "/library/metadata/45870/thumb/1788156492"
      {:ok, {"image/jpeg", "JPEGBYTES"}}
    end)

    assert {:ok, path, "image/jpeg"} = Fanfarr.Posters.path_for(item)
    assert File.read!(path) == "JPEGBYTES"
    assert String.ends_with?(path, ".jpg")

    # Second call: the expectation above allows exactly one fetch.
    assert {:ok, ^path, "image/jpeg"} = Fanfarr.Posters.path_for(item)
  end

  test "a changed thumb key is a different cache entry", %{item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_image, 2, fn _c, _k, _o ->
      {:ok, {"image/png", "PNG"}}
    end)

    {:ok, first, _} = Fanfarr.Posters.path_for(item)

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "45870",
        section_id: item.section_id,
        title: "x",
        kind: :show,
        plex_thumb_key: "/library/metadata/45870/thumb/2"
      })

    {:ok, second, "image/png"} = Fanfarr.Posters.path_for(item)

    assert first != second
  end

  test "a failed fetch is not cached, so it is retried", %{item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_image, 2, fn _c, _k, _o -> {:error, :timeout} end)

    assert {:error, :timeout} = Fanfarr.Posters.path_for(item)
    assert {:error, :timeout} = Fanfarr.Posters.path_for(item)
  end

  test "no thumb key means no fetch", %{item: item} do
    item = %{item | plex_thumb_key: nil}
    assert {:error, :no_thumb} = Fanfarr.Posters.path_for(item)
  end
end
