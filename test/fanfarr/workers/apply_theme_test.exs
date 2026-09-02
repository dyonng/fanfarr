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
    setup ctx do
      # A read-only mount rather than chmod: the suite runs as root here, and
      # root ignores permission bits, so a chmod-based test would pass while
      # proving nothing. CI cannot mount, so it skips rather than failing --
      # visibly, as a reported skip.
      ro = Path.join(ctx.root, "readonly")
      media = Path.join(ro, "One Piece (1999)")
      File.mkdir_p!(ro)

      with {_, 0} <-
             System.cmd("mount", ["-t", "tmpfs", "-o", "size=1m", "tmpfs", ro],
               stderr_to_stdout: true
             ),
           :ok <- File.mkdir_p(media),
           {_, 0} <- System.cmd("mount", ["-o", "remount,ro", ro], stderr_to_stdout: true) do
        on_exit(fn -> System.cmd("umount", [ro], stderr_to_stdout: true) end)
        %{readonly_media: media}
      else
        _ ->
          System.cmd("umount", [ro], stderr_to_stdout: true)
          {:skip, "needs privileges to mount a read-only filesystem"}
      end
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

  describe "refusals" do
    test "a locked theme is never touched", ctx do
      themerr_hit()
      item = item(ctx)
      item = Ash.Changeset.for_update(item, :update, %{theme_locked: true}) |> Ash.update!()

      assert {:cancel, :theme_locked} = run(item, %{"dry_run" => false})
    end

    test "movies are refused until the behaviour is verified on a real server", ctx do
      item = item(ctx, %{kind: :movie, title: "Heat"})

      # Plex's movie agent supplies no themes, and whether it reads a local
      # theme file for a movie is unverified. Refusing beats guessing on 1,785
      # irreversible writes.
      assert {:cancel, :movies_not_supported_yet} = run(item, %{"dry_run" => false})
    end

    test "an unmapped path is a configuration problem, not a retry", ctx do
      themerr_hit()
      item = item(ctx, %{plex_path: nil})

      assert {:cancel, :no_plex_path} = run(item, %{"dry_run" => false})
    end
  end
end
