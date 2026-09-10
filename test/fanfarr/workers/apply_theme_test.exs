defmodule Fanfarr.Workers.ApplyThemeTest do
  @moduledoc """
  The apply pipeline against a mocked downloader and a real filesystem.

  The filesystem half is deliberately real: the whole point of this worker is
  where the bytes end up.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  alias Fanfarr.Themes
  alias Fanfarr.Workers.ApplyTheme

  setup :verify_on_exit!

  setup do
    root = Path.join(System.tmp_dir!(), "fanfarr-apply-#{:erlang.unique_integer([:positive])}")
    media = Path.join([root, "tv", "One Piece (1999)"])
    File.mkdir_p!(media)
    on_exit(fn -> File.rm_rf(root) end)

    section =
      Fanfarr.Library.sync_section_from_plex!(%{
        plex_key: "1",
        title: "TV Shows",
        kind: :show
      })

    %{root: root, media: media, section: section}
  end

  defp item(ctx, over \\ %{}) do
    Fanfarr.Library.sync_media_item_from_plex!(
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

  defp themerr_hit(url \\ "https://www.youtube.com/watch?v=abc123") do
    Themes.record_themerr_lookup!(%{
      item_type: :tv_shows,
      database: :imdb,
      external_id: "tt0388629",
      found: true,
      youtube_theme_url: url
    })
  end

  # ThemerrDB keys movies separately from shows, so a movie needs its own entry.
  defp themerr_movie_hit(url \\ "https://www.youtube.com/watch?v=abc123") do
    Themes.record_themerr_lookup!(%{
      item_type: :movies,
      database: :imdb,
      external_id: "tt0388629",
      found: true,
      youtube_theme_url: url
    })
  end

  defp run(item, args \\ %{}) do
    ApplyTheme.perform(%Oban.Job{
      args: Map.merge(%{"media_item_id" => item.id}, args)
    })
  end

  defp history(item), do: Themes.theme_history_for_item!(item.id)

  # For tests about planning rather than about the audio: the download is not
  # what is under test, it just has to happen for the run to reach the end.
  defp stub_download do
    stub(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
      file = Path.join(dir, "theme.mp3")
      File.write!(file, "the-audio")
      {:ok, %{path: file, bytes: 9, codec: "mp3", duration: 90.0}}
    end)
  end

  describe "an unwritable destination" do
    @describetag :requires_mount

    setup ctx do
      # A read-only mount rather than chmod: the suite runs as root where it
      # can mount, and root ignores permission bits, so a chmod-based test
      # would pass while proving nothing. Where mounting is not permitted the
      # tag excludes these tests outright -- see test_helper.exs.
      ro = Path.join(ctx.root, "readonly")
      media = Path.join(ro, "One Piece (1999)")
      File.mkdir_p!(ro)

      {output, status} =
        System.cmd("mount", ["-t", "tmpfs", "-o", "size=1m", "tmpfs", ro], stderr_to_stdout: true)

      assert status == 0, "could not mount tmpfs: #{output}"
      File.mkdir_p!(media)

      {remount, remount_status} =
        System.cmd("mount", ["-o", "remount,ro", ro], stderr_to_stdout: true)

      assert remount_status == 0, "could not remount read-only: #{remount}"
      on_exit(fn -> System.cmd("umount", [ro], stderr_to_stdout: true) end)

      %{readonly_media: media}
    end

    test "it is reported before anything is downloaded", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: ctx.readonly_media})

      # No downloader expectation: writability is checked first, so
      # verify_on_exit! fails if audio was fetched for a file that could never
      # have been written.
      assert {:cancel, {:destination_not_writable, _}} = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :failed
    end
  end

  describe "planning" do
    test "an item with no ThemerrDB entry is skipped, not retried", ctx do
      item = item(ctx)

      assert {:cancel, :no_themerrdb_entry} = run(item)

      [outcome] = history(item)
      assert outcome.status == :skipped
    end
  end

  describe "applying for real" do
    test "downloads, writes theme.mp3, and records the outcome", ctx do
      themerr_hit()
      item = item(ctx)

      expect(Fanfarr.ThemeDownloaderMock, :download, fn url, dir ->
        assert url == "https://www.youtube.com/watch?v=abc123"
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "the-audio")
        {:ok, %{path: file, bytes: 9, codec: "mp3", duration: 88.0}}
      end)

      assert :ok = run(item)

      written = Path.join(ctx.media, "theme.mp3")
      assert File.read!(written) == "the-audio"

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      assert outcome.codec == "mp3"
      assert outcome.bytes == 9

      # The library now knows, so the dashboard stops listing it as missing.
      reloaded = Fanfarr.Library.get_media_item!(item.id)
      assert reloaded.local_theme_present
      assert Ash.load!(reloaded, :theme_status).theme_status == :fanfarr_applied
    end

    test "a download failure leaves no file and is recorded", ctx do
      themerr_hit()
      item = item(ctx)

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, _dir ->
        {:error, :unavailable}
      end)

      # Cancelled, not retried: a video YouTube has taken down answers the same
      # way on every attempt, and five tries with backoff only keep the item
      # sitting in the queue looking like work in progress.
      assert {:cancel, :unavailable} = run(item)

      refute File.exists?(Path.join(ctx.media, "theme.mp3"))
      [outcome | _] = history(item)
      assert outcome.status == :failed
      assert outcome.error =~ "YouTube no longer has this video"
    end

    test "a rejected URL is cancelled rather than retried forever", ctx do
      themerr_hit()
      item = item(ctx)

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, _dir ->
        {:error, :unsupported_url}
      end)

      assert {:cancel, :unsupported_url} = run(item)
    end

    test "the scratch directory is cleaned up", ctx do
      themerr_hit()
      item = item(ctx)
      parent = System.tmp_dir!()
      before = Path.wildcard(Path.join(parent, "fanfarr-dl-*"))

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "x")
        {:ok, %{path: file, bytes: 1, codec: "mp3", duration: 1.0}}
      end)

      assert :ok = run(item)
      assert Path.wildcard(Path.join(parent, "fanfarr-dl-*")) == before
    end
  end

  describe "handing the written file over to Plex" do
    setup do
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")
      :ok
    end

    defp downloads_ok do
      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "the-audio")
        {:ok, %{path: file, bytes: 9, codec: "mp3", duration: 88.0}}
      end)
    end

    test "scans the folder, refreshes, and promotes a theme Plex listed but did not serve",
         ctx do
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      key = "metadata://themes/46f33324b3bba73680ef38c5de0cd89664a55a1c"
      test_pid = self()

      expect(Fanfarr.PlexClientMock, :scan_directory, fn _c, "1", path ->
        assert path == ctx.media
        send(test_pid, :scanned)
        :ok
      end)

      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k ->
        send(test_pid, :refreshed)
        :ok
      end)

      # Listed and unselected until asked for by name; served afterwards.
      Agent.start_link(fn -> false end, name: :selected?)

      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k ->
        if Agent.get(:selected?, & &1),
          do: {:ok, %{"theme" => "/library/metadata/1/theme/9"}},
          else: {:ok, %{}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k ->
        {:ok,
         [
           %{
             rating_key: key,
             key: "/library/metadata/1/file",
             selected: Agent.get(:selected?, & &1),
             origin: :local,
             agent: nil
           }
         ]}
      end)

      expect(Fanfarr.PlexClientMock, :select_theme, fn _c, _k, asked ->
        assert asked == key
        Agent.update(:selected?, fn _ -> true end)
        send(test_pid, :selected)
        :ok
      end)

      assert :ok = run(item)

      assert_received :scanned
      assert_received :refreshed
      assert_received :selected

      # What Plex ended up serving is stored, so the badge agrees with it.
      reloaded = Fanfarr.Library.get_media_item!(item.id)
      assert reloaded.plex_theme_origin == :local
      assert reloaded.plex_theme_url == "/library/metadata/1/theme/9"
    end

    test "a theme Plex is already serving is not re-selected", ctx do
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> :ok end)
      stub(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> :ok end)

      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k ->
        {:ok, %{"theme" => "/library/metadata/1/theme/9"}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k ->
        {:ok,
         [
           %{
             rating_key: "metadata://themes/46f33324b3bba73680ef38c5de0cd89664a55a1c",
             key: "/k",
             selected: true,
             origin: :local,
             agent: nil
           }
         ]}
      end)

      # Neither select_theme nor upload_theme is expected: calling either fails
      # the test, which is the assertion that a served theme is left alone.
      assert :ok = run(item)
    end

    test "a locked theme field goes straight to upload, without trying to select",
         ctx do
      # Verified on a live server: with `theme` locked, Plex's agents will not
      # write it however many times the folder is scanned, and the local file
      # sits listed and unselected forever. An upload sets the field directly.
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> :ok end)
      stub(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> :ok end)

      Agent.start_link(fn -> false end, name: :sent?)

      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k ->
        base = %{"Field" => [%{"name" => "theme", "locked" => true}]}

        if Agent.get(:sent?, & &1),
          do: {:ok, Map.put(base, "theme", "/library/metadata/1/theme/9")},
          else: {:ok, base}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k ->
        if Agent.get(:sent?, & &1),
          do:
            {:ok,
             [
               %{
                 rating_key: "upload://themes/a",
                 key: "/k",
                 selected: true,
                 origin: :uploaded,
                 agent: nil
               }
             ]},
          else:
            {:ok,
             [
               %{
                 rating_key: "metadata://themes/abc123def",
                 key: "/k",
                 selected: false,
                 origin: :local,
                 agent: nil
               }
             ]}
      end)

      # No select_theme expectation: calling it fails the test, which is the
      # assertion that a locked field skips straight past it.
      expect(Fanfarr.PlexClientMock, :upload_theme, fn _c, _k, {:file, path} ->
        assert path == Path.join(ctx.media, "theme.mp3")
        Agent.update(:sent?, fn _ -> true end)
        :ok
      end)

      assert :ok = run(item)

      reloaded = Fanfarr.Library.get_media_item!(item.id)
      assert reloaded.plex_theme_origin == :uploaded
      assert reloaded.theme_locked
    end

    test "a refused selection falls back to uploading", ctx do
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> :ok end)
      stub(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> :ok end)

      Agent.start_link(fn -> false end, name: :uploaded?)

      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k ->
        if Agent.get(:uploaded?, & &1),
          do: {:ok, %{"theme" => "/library/metadata/1/theme/9"}},
          else: {:ok, %{}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k ->
        if Agent.get(:uploaded?, & &1),
          do:
            {:ok,
             [
               %{
                 rating_key: "upload://themes/a",
                 key: "/k",
                 selected: true,
                 origin: :uploaded,
                 agent: nil
               }
             ]},
          else:
            {:ok,
             [
               %{
                 rating_key: "metadata://themes/abc123def",
                 key: "/k",
                 selected: false,
                 origin: :local,
                 agent: nil
               }
             ]}
      end)

      # The 500 a live server actually answered.
      expect(Fanfarr.PlexClientMock, :select_theme, fn _c, _k, _t ->
        {:error, {:http, 500, ""}}
      end)

      expect(Fanfarr.PlexClientMock, :upload_theme, fn _c, _k, {:file, _path} ->
        Agent.update(:uploaded?, fn _ -> true end)
        :ok
      end)

      assert :ok = run(item)
      assert Fanfarr.Library.get_media_item!(item.id).plex_theme_origin == :uploaded
    end

    test "an upload Plex will not take still leaves a good write", ctx do
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> :ok end)
      stub(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> :ok end)
      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k -> {:ok, []} end)

      expect(Fanfarr.PlexClientMock, :upload_theme, fn _c, _k, _f ->
        {:error, {:http, 500, "no"}}
      end)

      assert :ok = run(item)
      assert File.read!(Path.join(ctx.media, "theme.mp3")) == "the-audio"
      [outcome | _] = history(item)
      assert outcome.status == :succeeded
    end

    test "a Plex that refuses every step does not fail a good write", ctx do
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> {:error, {:http, 500}} end)
      stub(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> {:error, :timeout} end)
      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k -> {:error, :timeout} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k -> {:error, :timeout} end)

      assert :ok = run(item)

      # The bytes are on disk and correct, which is what the job was for.
      assert File.read!(Path.join(ctx.media, "theme.mp3")) == "the-audio"
      [outcome | _] = history(item)
      assert outcome.status == :succeeded
    end
  end

  describe "which URL gets applied" do
    test "the operator's pick outranks ThemerrDB", ctx do
      themerr_hit("https://www.youtube.com/watch?v=fromthemerr")
      item = item(ctx)

      item =
        Fanfarr.Library.set_manual_theme!(item, %{
          manual_theme_url: "https://youtu.be/mypick00000",
          manual_theme_title: "My pick"
        })

      expect(Fanfarr.ThemeDownloaderMock, :download, fn url, dir ->
        assert url == "https://youtu.be/mypick00000"
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "x")
        {:ok, %{path: file, bytes: 1, codec: "mp3", duration: 1.0}}
      end)

      assert :ok = run(item)
      [outcome | _] = history(item)
      assert outcome.source == :youtube
      assert outcome.theme_url == "https://youtu.be/mypick00000"
    end

    test "a URL passed with the job outranks both", ctx do
      themerr_hit()
      item = item(ctx)
      Fanfarr.Library.set_manual_theme!(item, %{manual_theme_url: "https://youtu.be/mypick00000"})

      expect(Fanfarr.ThemeDownloaderMock, :download, fn url, dir ->
        assert url == "https://youtu.be/explicit000"
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "x")
        {:ok, %{path: file, bytes: 1, codec: "mp3", duration: 1.0}}
      end)

      assert :ok =
               run(item, %{"theme_url" => "https://youtu.be/explicit000", "source" => "youtube"})

      [outcome | _] = history(item)
      assert outcome.theme_url == "https://youtu.be/explicit000"
    end

    test "with no pick and no entry, it is skipped with a reason", ctx do
      item = item(ctx)
      assert {:cancel, :no_themerrdb_entry} = run(item)
    end
  end

  describe "trimming" do
    # Real audio and real ffmpeg: the whole point of these is that the file
    # written next to the media is shorter than the one downloaded, and a
    # stubbed cutter would assert only that we called ourselves.
    defp tone(dir, seconds) do
      path = Path.join(dir, "theme.mp3")

      {_out, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=#{seconds} -c:a libmp3lame) ++
            [path],
          stderr_to_stdout: true
        )

      path
    end

    defp duration(path) do
      {out, 0} =
        System.cmd(
          "ffprobe",
          ~w(-v error -show_entries format=duration -of default=nw=1:nk=1) ++ [path],
          stderr_to_stdout: true
        )

      out |> String.trim() |> String.to_float()
    end

    test "the written file is the chosen range, not the whole download", ctx do
      themerr_hit()

      item =
        ctx
        |> item()
        |> Fanfarr.Library.set_theme_trim!(%{theme_start_ms: 4_000, theme_end_ms: 14_000})

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        path = tone(dir, 30)
        {:ok, %{path: path, bytes: File.stat!(path).size, codec: "mp3", duration: 30.0}}
      end)

      assert :ok = run(item)

      written = Path.join(ctx.media, "theme.mp3")
      assert_in_delta duration(written), 10.0, 0.3
    end

    test "the log says what range was written", ctx do
      # Two applies of one URL can produce different files. Without this the
      # history cannot explain why, which is the job of an append-only record.
      themerr_hit()

      item =
        ctx
        |> item()
        |> Fanfarr.Library.set_theme_trim!(%{theme_start_ms: 2_000, theme_end_ms: 9_000})

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        path = tone(dir, 20)
        {:ok, %{path: path, bytes: File.stat!(path).size, codec: "mp3", duration: 20.0}}
      end)

      assert :ok = run(item)

      [outcome, intent] = history(item)
      assert intent.start_ms == 2_000 and intent.end_ms == 9_000
      assert outcome.start_ms == 2_000 and outcome.end_ms == 9_000
    end

    test "an untrimmed item is not re-encoded at all", ctx do
      # Running ffmpeg to produce the same audio spends a generation of lossy
      # loss for nothing. The proof is the byte-for-byte match: a re-encode,
      # even to the same settings, does not round-trip identically.
      themerr_hit()
      item = item(ctx)
      downloaded = :erlang.unique_integer([:positive])

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        path = tone(dir, 5)
        File.write!(Path.join(dir, "copy-#{downloaded}"), File.read!(path))
        {:ok, %{path: path, bytes: File.stat!(path).size, codec: "mp3", duration: 5.0}}
      end)

      assert :ok = run(item)

      # Fades default to on, but with no crop there is nothing to fade into or
      # out of, so trims?/1 says no and the download is placed untouched.
      assert item.theme_start_ms == nil and item.theme_end_ms == nil
      assert_in_delta duration(Path.join(ctx.media, "theme.mp3")), 5.0, 0.2
    end

    test "the trim is read at run time, not baked into the job", ctx do
      # A bulk apply can sit in the queue for a long while. Reading the crop
      # off the item when the worker runs means an edit made in the meantime
      # is what gets written, rather than whatever was true when it queued.
      themerr_hit()
      item = item(ctx)

      {:ok, _job} = ApplyTheme.enqueue(item)

      item = Fanfarr.Library.set_theme_trim!(item, %{theme_start_ms: 1_000, theme_end_ms: 6_000})

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        path = tone(dir, 20)
        {:ok, %{path: path, bytes: File.stat!(path).size, codec: "mp3", duration: 20.0}}
      end)

      assert :ok = run(item)
      assert_in_delta duration(Path.join(ctx.media, "theme.mp3")), 5.0, 0.3
    end
  end

  describe "enqueue/2" do
    test "it carries an explicit URL and source through to the job", ctx do
      item = item(ctx)

      assert {:ok, %Oban.Job{}} =
               ApplyTheme.enqueue(item.id,
                 theme_url: "https://youtu.be/abc",
                 source: :youtube
               )

      # Read back from the database, where the keys are strings.
      [job] = Fanfarr.Repo.all(Oban.Job) |> Enum.filter(&(&1.worker =~ "ApplyTheme"))

      assert job.args["theme_url"] == "https://youtu.be/abc"
      assert job.args["source"] == "youtube"
    end

    test "picking a second video is a second job, not a duplicate", ctx do
      # The uniqueness window is five minutes and keyed on the URL as well as
      # the item. Keyed on the item alone, changing your mind about a theme
      # within that window would be silently dropped -- which is exactly the
      # pace someone auditions two videos at.
      item = item(ctx)
      {:ok, first} = ApplyTheme.enqueue(item, theme_url: "https://youtu.be/first00000")
      {:ok, second} = ApplyTheme.enqueue(item, theme_url: "https://youtu.be/second0000")

      refute second.conflict?, "the second pick was deduplicated against the first"
      assert first.id != second.id
    end
  end

  describe "loudness" do
    test "the file is recorded with the loudness it ended up at", ctx do
      themerr_hit()
      item = item(ctx)

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "audio")
        {:ok, %{path: file, bytes: 5, codec: "mp3", duration: 90.0}}
      end)

      assert :ok = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :succeeded

      # Without ffmpeg the apply still succeeds and simply records no loudness:
      # an unnormalised theme is far better than no theme.
      case Fanfarr.Themes.Normalizer.version() do
        {:ok, _} -> assert is_float(outcome.loudness_lufs) or is_nil(outcome.loudness_lufs)
        {:error, _} -> assert is_nil(outcome.loudness_lufs)
      end
    end

    @tag :requires_ffmpeg
    test "real audio is normalised on its way to the destination", ctx do
      themerr_hit()
      item = item(ctx)

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        file = Path.join(dir, "theme.mp3")

        {_, 0} =
          System.cmd(
            "ffmpeg",
            [
              "-hide_banner",
              "-loglevel",
              "error",
              "-f",
              "lavfi",
              "-i",
              "sine=frequency=440:duration=5",
              "-af",
              "volume=0dB",
              "-c:a",
              "libmp3lame",
              "-b:a",
              "192k",
              file
            ],
            stderr_to_stdout: true
          )

        {:ok, %{path: file, bytes: File.stat!(file).size, codec: "mp3", duration: 5.0}}
      end)

      assert :ok = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      assert_in_delta outcome.loudness_lufs, Fanfarr.Themes.Normalizer.target(), 1.0

      # The recorded size must be the file that was actually written, not the
      # one before re-encoding.
      written = Path.join(ctx.media, "theme.mp3")
      assert outcome.bytes == File.stat!(written).size
    end
  end

  describe "a host path the container cannot see" do
    # The reported case. Plex runs on the host and says
    # /media/red-10-redemption/TV/One Pace. That path does not exist in the
    # container, which mounts the same drives as /tv1../tv5. Root folders are
    # the whole mechanism for this, and an earlier version rejected the item
    # before consulting them.
    setup ctx do
      drives = for n <- 1..5, do: Path.join(ctx.root, "tv#{n}")
      Enum.each(drives, &File.mkdir_p!/1)
      # Only one drive actually holds the show.
      File.mkdir_p!(Path.join(ctx.root, "tv2/One Pace"))
      Enum.each(drives, &Fanfarr.Library.create_root_folder!(%{path: &1, kind: :show}))

      %{drives: drives}
    end

    test "resolves through the root folders and writes there", ctx do
      item =
        item(ctx, %{
          title: "One Pace",
          plex_path: "/media/red-10-redemption/TV/One Pace"
        })

      item =
        Fanfarr.Library.set_manual_theme!(item, %{
          manual_theme_url: "https://www.youtube.com/watch?v=VHxeuLf_eRs",
          manual_theme_title: "ANGEL & DEVIL"
        })

      refute File.dir?("/media/red-10-redemption/TV/One Pace"),
             "the premise: the reported path is not visible here"

      expect(Fanfarr.ThemeDownloaderMock, :download, fn url, dir ->
        assert url == "https://www.youtube.com/watch?v=VHxeuLf_eRs"
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "the-audio")
        {:ok, %{path: file, bytes: 9, codec: "mp3", duration: 90.0}}
      end)

      assert :ok = run(item)

      written = Path.join([ctx.root, "tv2/One Pace", "theme.mp3"])
      assert File.read!(written) == "the-audio"

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      assert outcome.destination_path == written
    end

    test "the resolved destination is recorded, not the reported path", ctx do
      item = item(ctx, %{title: "One Pace", plex_path: "/media/red-10-redemption/TV/One Pace"})
      Fanfarr.Library.set_manual_theme!(item, %{manual_theme_url: "https://youtu.be/abc12345678"})

      stub_download()
      assert :ok = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      assert outcome.destination_path == Path.join([ctx.root, "tv2/One Pace", "theme.mp3"])
    end

    test "a show no root folder holds says so, naming the path", ctx do
      item = item(ctx, %{title: "Nowhere", plex_path: "/media/red-10-redemption/TV/Nowhere"})
      Fanfarr.Library.set_manual_theme!(item, %{manual_theme_url: "https://youtu.be/abc12345678"})

      assert {:cancel, {:no_matching_root, "/media/red-10-redemption/TV/Nowhere"}} = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :skipped

      # The history row is where this is read, so it is a sentence naming the
      # path rather than an inspected tuple.
      assert outcome.error =~ "No root folder holds"
      assert outcome.error =~ "/media/red-10-redemption/TV/Nowhere"
    end
  end

  describe "with root folders configured" do
    # The case that crashed in the dev server: every earlier test ran with no
    # root folders and so never reached resolve/2 with a non-empty list.
    test "the item is located by directory name under the matching root", ctx do
      pool = Path.join(ctx.root, "pool")
      drive = Path.join(ctx.root, "tv2")
      File.mkdir_p!(Path.join(pool, "One Piece (1999)"))
      File.mkdir_p!(Path.join(drive, "One Piece (1999)"))
      Fanfarr.Library.create_root_folder!(%{path: drive, kind: :show})
      Fanfarr.Library.create_root_folder!(%{path: Path.join(ctx.root, "movies1"), kind: :movie})

      themerr_hit()
      item = item(ctx, %{plex_path: Path.join(pool, "One Piece (1999)")})

      stub_download()
      assert :ok = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      # Written to the drive that holds the show, not the pool path Plex reported.
      assert outcome.destination_path == Path.join([drive, "One Piece (1999)", "theme.mp3"])
    end

    test "a movies-only root is ignored for a show, which falls back to the reported path", ctx do
      pool = Path.join(ctx.root, "pool")
      movies = Path.join(ctx.root, "movies1")
      File.mkdir_p!(Path.join(pool, "One Piece (1999)"))
      File.mkdir_p!(Path.join(movies, "One Piece (1999)"))
      Fanfarr.Library.create_root_folder!(%{path: movies, kind: :movie})

      themerr_hit()
      item = item(ctx, %{plex_path: Path.join(pool, "One Piece (1999)")})

      stub_download()
      assert :ok = run(item)
      [outcome | _] = history(item)
      # Not the movies drive, even though a same-named directory exists there.
      assert outcome.destination_path == Path.join([pool, "One Piece (1999)", "theme.mp3"])
    end
  end

  describe "refusals" do
    test "a locked theme is never touched", ctx do
      themerr_hit()
      item = item(ctx)
      item = Ash.Changeset.for_update(item, :update, %{theme_locked: true}) |> Ash.update!()

      assert {:cancel, :theme_locked} = run(item)
    end

    test "a movie in its own folder is written like anything else", ctx do
      themerr_movie_hit()
      media = Path.join([ctx.root, "movies", "Heat (1995)"])
      File.mkdir_p!(media)

      Fanfarr.Library.create_root_folder!(%{
        path: Path.join(ctx.root, "movies"),
        kind: :movie,
        enabled: true
      })

      item = item(ctx, %{kind: :movie, title: "Heat", plex_path: media})

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, dir ->
        file = Path.join(dir, "theme.mp3")
        File.write!(file, "the-audio")
        {:ok, %{path: file, bytes: 9, codec: "mp3", duration: 88.0}}
      end)

      assert :ok = run(item)
      assert File.read!(Path.join(media, "theme.mp3")) == "the-audio"
    end

    test "a movie loose in a library root is refused rather than themed", ctx do
      themerr_movie_hit()
      movies = Path.join(ctx.root, "movies")
      File.mkdir_p!(movies)

      Fanfarr.Library.create_root_folder!(%{path: movies, kind: :movie, enabled: true})

      # Plex reports a movie's folder from its media file, so Heat.mkv sitting
      # directly in the root resolves to the root. theme.mp3 written there is
      # every neighbouring film's theme, not this one's.
      item = item(ctx, %{kind: :movie, title: "Heat", plex_path: movies})

      assert {:cancel, {:not_in_own_folder, _}} = run(item)
      refute File.exists?(Path.join(movies, "theme.mp3"))
    end

    test "an item Plex gave no path at all is a configuration problem, not a retry", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: nil})

      assert {:cancel, :no_plex_path} = run(item)
    end

    test "with no root folders, a path the container cannot see is named", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: "/media/red-10-redemption/TV/One Pace"})

      # Nothing configured to bridge host paths to container mounts.
      assert {:cancel, {:destination_missing, "/media/red-10-redemption/TV/One Pace"}} =
               run(item)
    end
  end
end
