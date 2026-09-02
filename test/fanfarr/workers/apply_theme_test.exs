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

  describe "dry run (the default)" do
    test "plans without downloading or writing anything", ctx do
      themerr_hit()
      item = item(ctx)

      # No downloader expectation is set: verify_on_exit! turns any call into a
      # failure, which is the assertion.
      assert :ok = run(item)

      refute File.exists?(Path.join(ctx.media, "theme.mp3"))

      [outcome, intent] = history(item)
      assert intent.status == :pending
      assert intent.dry_run
      assert outcome.status == :succeeded
      assert outcome.dry_run
      assert outcome.destination_path == Path.join(ctx.media, "theme.mp3")
    end
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

    test "a dry run reports it rather than succeeding", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: ctx.readonly_media})

      assert {:cancel, {:destination_not_writable, _}} = run(item)

      [outcome | _] = history(item)
      assert outcome.status == :failed
      # Finding this in a dry run is the entire reason dry run checks it.
      assert outcome.dry_run
    end
  end

  describe "more dry run" do
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

      assert :ok = run(item, %{"dry_run" => false})

      written = Path.join(ctx.media, "theme.mp3")
      assert File.read!(written) == "the-audio"

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      refute outcome.dry_run
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

      assert {:error, :unavailable} = run(item, %{"dry_run" => false})

      refute File.exists?(Path.join(ctx.media, "theme.mp3"))
      [outcome | _] = history(item)
      assert outcome.status == :failed
      assert outcome.error =~ "unavailable"
    end

    test "a rejected URL is cancelled rather than retried forever", ctx do
      themerr_hit()
      item = item(ctx)

      expect(Fanfarr.ThemeDownloaderMock, :download, fn _url, _dir ->
        {:error, :unsupported_url}
      end)

      assert {:cancel, :unsupported_url} = run(item, %{"dry_run" => false})
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

      assert :ok = run(item, %{"dry_run" => false})
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

      assert :ok = run(item, %{"dry_run" => false})

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

      # No select_theme expectation: verify_on_exit! fails the test if one is
      # called, which is the assertion.
      assert :ok = run(item, %{"dry_run" => false})
    end

    test "a Plex that refuses every step does not fail a good write", ctx do
      themerr_hit()
      item = item(ctx)
      downloads_ok()

      stub(Fanfarr.PlexClientMock, :scan_directory, fn _c, _s, _p -> {:error, {:http, 500}} end)
      stub(Fanfarr.PlexClientMock, :refresh_metadata, fn _c, _k -> {:error, :timeout} end)
      stub(Fanfarr.PlexClientMock, :metadata, fn _c, _k -> {:error, :timeout} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _c, _k -> {:error, :timeout} end)

      assert :ok = run(item, %{"dry_run" => false})

      # The bytes are on disk and correct, which is what the job was for.
      assert File.read!(Path.join(ctx.media, "theme.mp3")) == "the-audio"
      [outcome | _] = history(item)
      assert outcome.status == :succeeded
    end

    test "a dry run tells Plex nothing", ctx do
      themerr_hit()
      item = item(ctx)

      # No downloader and no Plex expectations at all: a preview that touched
      # the server would not be a preview.
      assert :ok = run(item, %{"dry_run" => true})
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

      assert :ok = run(item, %{"dry_run" => false})
      [outcome | _] = history(item)
      assert outcome.source == :youtube
      assert outcome.theme_url == "https://youtu.be/mypick00000"
    end

    test "a URL passed with the job outranks both", ctx do
      themerr_hit()
      item = item(ctx)
      Fanfarr.Library.set_manual_theme!(item, %{manual_theme_url: "https://youtu.be/mypick00000"})

      assert :ok =
               run(item, %{"theme_url" => "https://youtu.be/explicit000", "source" => "youtube"})

      [outcome | _] = history(item)
      assert outcome.theme_url == "https://youtu.be/explicit000"
      assert outcome.dry_run
    end

    test "with no pick and no entry, it is skipped with a reason", ctx do
      item = item(ctx)
      assert {:cancel, :no_themerrdb_entry} = run(item)
    end
  end

  describe "enqueue/2" do
    test "defaults to a dry run and carries an explicit URL", ctx do
      item = item(ctx)
      assert {:ok, %Oban.Job{}} = ApplyTheme.enqueue(item)

      assert {:ok, %Oban.Job{}} =
               ApplyTheme.enqueue(item.id,
                 dry_run: false,
                 theme_url: "https://youtu.be/abc",
                 source: :youtube
               )

      # Read back from the database: string keys, and proof that the second
      # insert was not deduplicated against the first.
      [dry, real] =
        Fanfarr.Repo.all(Oban.Job)
        |> Enum.filter(&(&1.worker =~ "ApplyTheme"))
        |> Enum.sort_by(& &1.id)

      assert dry.args["dry_run"] == true
      assert real.args["dry_run"] == false
      assert real.args["theme_url"] == "https://youtu.be/abc"
      assert real.args["source"] == "youtube"
    end

    test "a queued dry run does not swallow the apply that follows it", ctx do
      item = item(ctx)
      {:ok, first} = ApplyTheme.enqueue(item, dry_run: true)
      {:ok, second} = ApplyTheme.enqueue(item, dry_run: false)

      refute second.conflict?, "the apply was deduplicated against the dry run"
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

      assert :ok = run(item, %{"dry_run" => false})

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

      assert :ok = run(item, %{"dry_run" => false})

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

      assert :ok = run(item, %{"dry_run" => false})

      written = Path.join([ctx.root, "tv2/One Pace", "theme.mp3"])
      assert File.read!(written) == "the-audio"

      [outcome | _] = history(item)
      assert outcome.status == :succeeded
      assert outcome.destination_path == written
    end

    test "a dry run reports the resolved destination, not the reported path", ctx do
      item = item(ctx, %{title: "One Pace", plex_path: "/media/red-10-redemption/TV/One Pace"})
      Fanfarr.Library.set_manual_theme!(item, %{manual_theme_url: "https://youtu.be/abc12345678"})

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
      assert outcome.error =~ "no_matching_root"
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

      assert {:cancel, :theme_locked} = run(item, %{"dry_run" => false})
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

      assert :ok = run(item, %{"dry_run" => false})
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

      assert {:cancel, {:not_in_own_folder, _}} = run(item, %{"dry_run" => false})
      refute File.exists?(Path.join(movies, "theme.mp3"))
    end

    test "an item Plex gave no path at all is a configuration problem, not a retry", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: nil})

      assert {:cancel, :no_plex_path} = run(item, %{"dry_run" => false})
    end

    test "with no root folders, a path the container cannot see is named", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: "/media/red-10-redemption/TV/One Pace"})

      # Nothing configured to bridge host paths to container mounts.
      assert {:cancel, {:destination_missing, "/media/red-10-redemption/TV/One Pace"}} =
               run(item, %{"dry_run" => false})
    end
  end
end
