defmodule Fanfarr.Themes.EditSourceTest do
  @moduledoc """
  Which audio the trim editor gets to scrub, and in what order of preference.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  alias Fanfarr.Library
  alias Fanfarr.Themes
  alias Fanfarr.Themes.EditSource
  alias Fanfarr.Themes.SourceCache

  @url "https://www.youtube.com/watch?v=abc12345678"

  setup do
    cache = Path.join(System.tmp_dir!(), "fanfarr-cache-#{System.unique_integer([:positive])}")
    media = Path.join(System.tmp_dir!(), "fanfarr-media-#{System.unique_integer([:positive])}")
    Application.put_env(:fanfarr, :cache_dir, cache)
    File.mkdir_p!(media)

    on_exit(fn ->
      File.rm_rf(cache)
      File.rm_rf(media)
      Application.delete_env(:fanfarr, :cache_dir)
    end)

    section = Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Library.sync_media_item_from_plex!(%{
        plex_rating_key: "rk-1",
        section_id: section.id,
        title: "One Piece",
        kind: :show
      })

    item = Library.set_manual_theme!(item, %{manual_theme_url: @url})

    %{item: item, media: media}
  end

  defp audio(dir, name \\ "theme.mp3") do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)

    # Opus in WebM for the "fresh download" fixtures, because that is what
    # YouTube actually serves and what the cache is built to keep unchanged.
    codec = if Path.extname(name) == ".webm", do: "libopus", else: "libmp3lame"

    {_out, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=1 -c:a #{codec}) ++
          [path],
        stderr_to_stdout: true
      )

    path
  end

  # An applied theme: the file on disk, plus the log row that says how it got
  # there. Both are needed -- the ladder reads the log, not the file.
  defp applied(item, media, trim \\ %{start_ms: nil, end_ms: nil}) do
    path = audio(media)

    Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: :youtube,
      method: :local_file,
      theme_url: @url,
      destination_path: path,
      start_ms: trim.start_ms,
      end_ms: trim.end_ms,
      status: :succeeded
    })

    Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: path})
  end

  test "a cached source is used, and nothing is fetched", %{item: item} do
    # No download_source expectation: verify_on_exit! turns a fetch into a
    # failure, which is the assertion.
    {:ok, _} = SourceCache.put(@url, audio(System.tmp_dir!(), "cached.mp3"), :source)

    assert {:ok, resolved} = EditSource.resolve(item)
    assert resolved.kind == :source
    assert resolved.url == @url
  end

  test "a theme applied whole seeds the editor without a download", %{item: item, media: media} do
    # The insight this rung is built on: an applied theme with no crop is a
    # faithful -- if lossy -- rendering of the whole source, so it is enough
    # to choose a range against.
    item = applied(item, media)

    assert {:ok, resolved} = EditSource.resolve(item)
    assert resolved.kind == :render

    # Cached as a render, so the waveform is computed once...
    assert {:ok, %{kind: :render}} = SourceCache.fetch(@url)

    # ...and never mistaken for something to render a written theme from.
    assert SourceCache.fetch_source(@url) == :miss
  end

  test "a theme applied with a crop cannot seed the editor", %{item: item, media: media} do
    # The hard boundary. The audio outside the crop is gone, so widening would
    # be impossible and the editor would offer a range it could not honour.
    item = applied(item, media, %{start_ms: 5_000, end_ms: 20_000})

    expect(Fanfarr.ThemeDownloaderMock, :download_source, fn @url, dir ->
      path = audio(dir, "fresh.webm")
      {:ok, %{path: path, bytes: 1, codec: "webm", duration: 1.0}}
    end)

    assert {:ok, resolved} = EditSource.resolve(item)
    assert resolved.kind == :source
  end

  test "with nothing to reuse it downloads the original stream", %{item: item} do
    expect(Fanfarr.ThemeDownloaderMock, :download_source, fn @url, dir ->
      path = audio(dir, "fresh.webm")
      {:ok, %{path: path, bytes: 1, codec: "webm", duration: 1.0}}
    end)

    assert {:ok, resolved} = EditSource.resolve(item)

    # The container it arrived in, not one we chose: re-encoding to store it
    # would spend fidelity for nothing.
    assert Path.extname(resolved.path) == ".webm"
    assert File.regular?(resolved.peaks)
  end

  test "an item with no theme chosen says so rather than downloading nothing", %{item: item} do
    Library.set_manual_theme!(item, %{manual_theme_url: nil})
    item = Library.get_media_item!(item.id)

    assert {:error, :no_theme_url} = EditSource.resolve(item)
  end

  test "a download failure is reported, not swallowed", %{item: item} do
    expect(Fanfarr.ThemeDownloaderMock, :download_source, fn _url, _dir ->
      {:error, :unavailable}
    end)

    assert {:error, :unavailable} = EditSource.resolve(item)
  end

  describe "reusable_render/2" do
    test "a render of a different url is not reusable", %{item: item, media: media} do
      # Re-picking a video invalidates the file on disk as an edit source, and
      # the log is what knows which URL produced it.
      item = applied(item, media)
      assert {:ok, _} = EditSource.reusable_render(item, @url)
      assert EditSource.reusable_render(item, "https://youtu.be/somethingelse") == :no
    end

    test "a missing file is not reusable however the log reads", %{item: item, media: media} do
      item = applied(item, media)
      File.rm!(item.local_theme_path)

      assert EditSource.reusable_render(item, @url) == :no
    end
  end
end
