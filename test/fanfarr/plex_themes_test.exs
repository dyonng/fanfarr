defmodule Fanfarr.PlexThemesTest do
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    dir =
      Path.join(System.tmp_dir!(), "fanfarr-plex-themes-#{:erlang.unique_integer([:positive])}")

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
        plex_theme_url: "/library/metadata/45870/theme/123"
      })

    %{item: item, dir: dir}
  end

  test "fetches once and serves from disk afterwards", %{item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_theme, 1, fn _config, key ->
      assert key == "/library/metadata/45870/theme/123"
      {:ok, {"audio/mpeg", "MP3BYTES"}}
    end)

    assert {:ok, path} = Fanfarr.PlexThemes.path_for(item)
    assert File.read!(path) == "MP3BYTES"
    assert String.ends_with?(path, ".mp3")

    # Second call: the expectation above allows exactly one fetch.
    assert {:ok, ^path} = Fanfarr.PlexThemes.path_for(item)
  end

  test "a changed theme key is a different cache entry", %{item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_theme, 2, fn _c, _k ->
      {:ok, {"audio/mp4", "M4A"}}
    end)

    {:ok, first} = Fanfarr.PlexThemes.path_for(item)

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "45870",
        section_id: item.section_id,
        title: "x",
        kind: :show,
        plex_theme_url: "/library/metadata/45870/theme/456"
      })

    assert {:ok, second} = Fanfarr.PlexThemes.path_for(item)
    assert first != second
    assert String.ends_with?(second, ".m4a")
  end

  test "a failed fetch is not cached, so it is retried", %{item: item} do
    expect(Fanfarr.PlexClientMock, :fetch_theme, 2, fn _c, _k -> {:error, :timeout} end)

    assert {:error, :timeout} = Fanfarr.PlexThemes.path_for(item)
    assert {:error, :timeout} = Fanfarr.PlexThemes.path_for(item)
  end

  test "no theme key means no fetch", %{item: item} do
    item = %{item | plex_theme_url: nil}
    assert {:error, :no_plex_theme} = Fanfarr.PlexThemes.path_for(item)
  end
end
