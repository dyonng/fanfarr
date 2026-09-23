defmodule Fanfarr.Workers.TrimThemeTest do
  @moduledoc """
  Finding a crop for an item's current theme, and cutting the file that is
  already on disk.

  Real audio, because the point of this worker is what it does to a file. The
  downloader is deliberately left unstubbed: if anything here reached for the
  network, Mox would fail the test rather than quietly pass it.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  alias Fanfarr.Library
  alias Fanfarr.Themes.ApplicationFacts
  alias Fanfarr.Workers.TrimTheme

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "fanfarr-trim-#{:erlang.unique_integer([:positive])}")
    media = Path.join([root, "tv", "One Piece (1999)"])
    File.mkdir_p!(media)
    on_exit(fn -> File.rm_rf(root) end)

    section = Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

    %{media: media, section: section}
  end

  defp item(ctx, over \\ %{}) do
    Library.sync_media_item_from_plex!(
      Map.merge(
        %{
          plex_rating_key: "rk-#{:erlang.unique_integer([:positive])}",
          section_id: ctx.section.id,
          title: "One Piece",
          kind: :show,
          imdb_id: "tt0388629",
          plex_path: ctx.media
        },
        over
      )
    )
  end

  defp write_theme(ctx, seconds \\ 4) do
    path = Path.join(ctx.media, "theme.mp3")

    {_output, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=#{seconds} -c:a libmp3lame) ++
          [path],
        stderr_to_stdout: true
      )

    path
  end

  # A hundred buckets over four seconds, twenty of them carrying the
  # attention. The timeline is the graph's own, so nothing has to be fetched
  # for the suggestion to be real.
  defp markers do
    for i <- 0..99 do
      %{
        start_time: i * 0.04,
        end_time: i * 0.04 + 0.04,
        value: if(i in 60..79, do: 1.0, else: 0.1)
      }
    end
  end

  defp croppable(ctx) do
    path = write_theme(ctx)

    ctx
    |> item()
    |> Library.set_manual_theme!(%{
      manual_theme_url: "https://www.youtube.com/watch?v=trimme00000"
    })
    |> Library.record_local_theme!(%{local_theme_present: true, local_theme_path: path})
  end

  defp perform(item) do
    TrimTheme.perform(%Oban.Job{args: %{"media_item_id" => item.id}})
  end

  defp queued_workers do
    Fanfarr.Repo.all(Oban.Job) |> Enum.map(& &1.worker)
  end

  test "cuts the file that is there, and records what it wrote", ctx do
    Fanfarr.Settings.put_setting!("auto_crop_target_ms", "2000")
    item = croppable(ctx)
    path = item.local_theme_path

    expect(Fanfarr.ThemeDownloaderMock, :heatmap, fn _url -> {:ok, markers()} end)

    assert perform(item) == :ok

    written = Library.get_media_item!(item.id)

    # A window of the configured length, wherever the graph put it, faded the
    # way the trimmer would have faded it by hand: 250 in, 500 out.
    assert written.theme_end_ms - written.theme_start_ms == 2_000
    assert written.theme_fade_in_ms == 250
    assert written.theme_fade_out_ms == 500

    # The file on disk really is shorter, and the log agrees with it -- the
    # Size and Length columns read the log rather than the file, so a trim that
    # recorded nothing would leave both describing the old theme.
    facts = ApplicationFacts.latest([item.id])
    assert facts[item.id].duration_ms == 2_000
    assert facts[item.id].bytes == File.stat!(path).size

    # Nothing was queued: this worker does the write itself now, rather than
    # handing it to the worker that would download the source again.
    refute "Fanfarr.Workers.ApplyTheme" in queued_workers()
  end

  test "a theme shorter than the crop is skipped, and says so", ctx do
    # Asked for by hand the floor is the crop length, so a 40-second theme has
    # nothing to cut. Named rather than lumped in with "no window could be
    # found": a length is not a listen, and the log is read by an operator
    # deciding whether to go and look at the file.
    path = write_theme(ctx, 40)

    item =
      ctx
      |> item()
      |> Library.set_manual_theme!(%{
        manual_theme_url: "https://www.youtube.com/watch?v=trimme00000"
      })
      |> Library.record_local_theme!(%{local_theme_present: true, local_theme_path: path})

    # A four-second graph cannot hold the crop either, so this is the graph
    # missing and the audio answering -- which is the path that has to reach
    # the length question at all.
    expect(Fanfarr.ThemeDownloaderMock, :heatmap, fn _url -> {:ok, markers()} end)

    # The audio path resolves the source before it can listen to it. Pointing
    # that at the file already beside the media keeps the test offline; the
    # source cache it lands in is shared per run and has to be cleared, or the
    # next test inherits this one's file.
    stub(Fanfarr.ThemeDownloaderMock, :download_source, fn _url, _dir ->
      {:ok, %{path: path}}
    end)

    on_exit(fn -> File.rm_rf!(Fanfarr.Themes.SourceCache.dir()) end)

    assert perform(item) == {:cancel, :too_short}
  end

  test "a crop the operator chose is left alone", ctx do
    item =
      ctx
      |> item()
      |> Library.set_theme_trim!(%{
        theme_start_ms: 1_000,
        theme_end_ms: 31_000,
        theme_fade_in_ms: 500,
        theme_fade_out_ms: 500
      })

    assert perform(item) == {:cancel, :already_cropped}

    # Nothing was cut and nothing was recorded, which is what makes this safe
    # to press twice: the second run over the same library writes nothing.
    assert ApplicationFacts.latest([item.id]) == %{}
  end

  test "a disabled feature cancels rather than guessing anyway", ctx do
    Fanfarr.Settings.put_setting!("auto_crop_enabled", "false")
    item = item(ctx)

    assert perform(item) == {:cancel, :crop_disabled}
    refute "Fanfarr.Workers.ApplyTheme" in queued_workers()
  end

  test "an item with no theme file is skipped", ctx do
    # A Plex-supplied theme has nothing on disk to cut, and fetching one would
    # be an apply rather than a trim.
    assert perform(item(ctx)) == {:cancel, :no_local_theme}
  end
end
