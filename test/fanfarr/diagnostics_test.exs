defmodule Fanfarr.DiagnosticsTest do
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  alias Fanfarr.Diagnostics
  alias Fanfarr.Diagnostics.Redactor

  setup do
    Redactor.forget_all()
    on_exit(fn -> Redactor.forget_all() end)

    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "2", title: "TV", kind: :show})
    %{section: section}
  end

  defp item(section, over) do
    Fanfarr.Library.sync_media_item_from_plex!(
      Map.merge(
        %{
          plex_rating_key: "101",
          section_id: section.id,
          title: "One Piece",
          year: 1999,
          kind: :show
        },
        over
      )
    )
  end

  describe "environment/0" do
    test "reports whether the token is set, never the token", %{section: _s} do
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "SUPER-SECRET-TOKEN")
      Redactor.prime()
      stub(Fanfarr.ThemeDownloaderMock, :version, fn -> {:ok, "2026.08.01"} end)

      text = Diagnostics.environment()

      assert text =~ "http://plex.test:32400"
      assert text =~ "Plex token      set"
      refute text =~ "SUPER-SECRET-TOKEN"
      assert text =~ "yt-dlp          2026.08.01"
    end
  end

  describe "item_report/1" do
    test "explains an item with no path, which is what :no_plex_path was", %{section: s} do
      item = item(s, %{plex_path: nil})

      text = Diagnostics.item_report(item.id)

      assert text =~ "One Piece"
      assert text =~ "Plex reported no path"
      assert text =~ "Sync again"
    end

    test "a host path bridged by a root folder reads as ready, not broken", %{section: s} do
      # The reported case: Plex says a host path the container cannot see, and
      # a root folder holds the show under a different mount name.
      root = Path.join(System.tmp_dir!(), "fanfarr-diag-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "tv2/One Pace"))
      on_exit(fn -> File.rm_rf(root) end)
      Fanfarr.Library.create_root_folder!(%{path: Path.join(root, "tv2"), kind: :show})

      item = item(s, %{title: "One Pace", plex_path: "/media/red-10-redemption/TV/One Pace"})

      text = Diagnostics.item_report(item.id)

      assert text =~ "exists here    false  (expected: root folders bridge this)"
      assert text =~ "verdict        ready"
      assert text =~ Path.join([root, "tv2/One Pace", "theme.mp3"])
    end

    test "warns when the resolved folder is a same-named folder on another drive",
         %{section: s} do
      # Five drives, two with a folder called "One Pace". The resolver matches
      # by name, so it can pick the wrong one; writing there succeeds and Plex
      # never plays the theme.
      root = Path.join(System.tmp_dir!(), "fanfarr-wrong-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "tv4/One Pace/Season 01"))
      on_exit(fn -> File.rm_rf(root) end)
      Fanfarr.Library.create_root_folder!(%{path: Path.join(root, "tv4"), kind: :show})

      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      expect(Fanfarr.PlexClientMock, :raw, fn _config, path ->
        assert path =~ "allLeaves"

        {:ok,
         %{
           "MediaContainer" => %{
             "Metadata" => [
               %{"Media" => [%{"Part" => [%{"file" => "/media/red-10/TV/One Pace/S01E01.mkv"}]}]}
             ]
           }
         }}
      end)

      item = item(s, %{title: "One Pace", plex_path: "/media/red-10/TV/One Pace"})

      text = Diagnostics.item_report(item.id)

      assert text =~ "same folder    NO"
      assert text =~ "S01E01.mkv"
    end

    test "confirms the folder when it holds the files Plex reports", %{section: s} do
      root = Path.join(System.tmp_dir!(), "fanfarr-right-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "tv2/One Pace/Season 01"))
      File.write!(Path.join([root, "tv2/One Pace/Season 01", "S01E01.mkv"]), "")
      on_exit(fn -> File.rm_rf(root) end)
      Fanfarr.Library.create_root_folder!(%{path: Path.join(root, "tv2"), kind: :show})

      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      expect(Fanfarr.PlexClientMock, :raw, fn _c, _p ->
        {:ok,
         %{
           "MediaContainer" => %{
             "Metadata" => [
               %{"Media" => [%{"Part" => [%{"file" => "/media/red-10/TV/One Pace/S01E01.mkv"}]}]}
             ]
           }
         }}
      end)

      item = item(s, %{title: "One Pace", plex_path: "/media/red-10/TV/One Pace"})

      assert Diagnostics.item_report(item.id) =~ "same folder    yes"
    end

    test "an item no root folder holds says what to do about it", %{section: s} do
      item = item(s, %{title: "Nowhere", plex_path: "/media/red-10-redemption/TV/Nowhere"})

      text = Diagnostics.item_report(item.id)

      assert text =~ "verdict        blocked"
      assert text =~ "does not exist in this container"
    end

    test "traces mapping, root resolution and writability", %{section: s} do
      root = Path.join(System.tmp_dir!(), "fanfarr-diag-#{:erlang.unique_integer([:positive])}")
      show = Path.join([root, "tv1", "One Piece (1999)"])
      File.mkdir_p!(show)
      on_exit(fn -> File.rm_rf(root) end)

      Fanfarr.Library.create_root_folder!(%{path: Path.join(root, "tv1"), kind: :show})
      item = item(s, %{plex_path: "/media/merged-storage/TV/One Piece (1999)"})

      text = Diagnostics.item_report(item.id)

      assert text =~ "Plex says      /media/merged-storage/TV/One Piece (1999)"
      assert text =~ "resolves to    #{show}"
      assert text =~ "writable       yes"
      assert text =~ "would write    #{Path.join(show, "theme.mp3")}"
    end
  end

  describe "plex_probe/1" do
    test "refuses anything that is not a server-relative path" do
      assert Diagnostics.plex_probe("https://evil.example/x") =~ "must start with a slash"
      assert Diagnostics.plex_probe("") =~ "Enter a path"
    end

    test "returns the server's response, redacted" do
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "SUPER-SECRET-TOKEN")
      Redactor.prime()

      expect(Fanfarr.PlexClientMock, :raw, fn _config, "/library/sections" ->
        {:ok, %{"MediaContainer" => %{"token" => "SUPER-SECRET-TOKEN", "size" => 2}}}
      end)

      text = Diagnostics.plex_probe("/library/sections")

      assert text =~ "GET /library/sections"
      assert text =~ ~s("size": 2)
      refute text =~ "SUPER-SECRET-TOKEN"
    end
  end

  describe "video_probe/1" do
    test "says a non-embeddable video is still downloadable" do
      expect(Fanfarr.ThemeDownloaderMock, :probe, fn url ->
        assert url == "https://www.youtube.com/watch?v=VHxeuLf_eRs"
        {:ok, %{title: "ANGEL & DEVIL", duration: 93, uploader: "GRe4N BOYZ"}}
      end)

      text = Diagnostics.video_probe("https://www.youtube.com/watch?v=VHxeuLf_eRs")

      assert text =~ "Downloadable: YES"
      assert text =~ "embedding is"
      assert text =~ "1m 33s"
    end

    test "distinguishes the reasons a video cannot be fetched" do
      expect(Fanfarr.ThemeDownloaderMock, :probe, fn _ -> {:error, :age_restricted} end)
      assert Diagnostics.video_probe("https://youtu.be/abc12345678") =~ "Age-restricted"

      assert Diagnostics.video_probe("https://evil.example/x") =~ "Not a YouTube URL"
    end
  end

  describe "routine_web?/1" do
    test "poster and asset traffic is noise" do
      for message <- [
            "GET /posters/20dd2a5a-31c5-4d99-8625-fd3fed80e604",
            "GET /assets/js/app-1e26.js",
            "GET /favicon.svg",
            "HEAD /apple-touch-icon.png",
            "GET /robots.txt",
            "Sent 200 in 3ms",
            "Sent 304 in 1ms",
            "CONNECTED TO Phoenix.LiveView.Socket in 83\u00b5s"
          ] do
        assert Fanfarr.Diagnostics.routine_web?(message), message
      end
    end

    test "a failed response is never noise" do
      # The 500 that started this was next to fifty poster requests. Hiding
      # those must not hide it.
      for message <- ["Sent 500 in 11ms", "Sent 404 in 2ms", "Sent 422 in 5ms"] do
        refute Fanfarr.Diagnostics.routine_web?(message), message
      end
    end

    test "requests that are not static keep their line, so a failure can be paired" do
      refute Fanfarr.Diagnostics.routine_web?("GET /library/ede41b43/theme")
      refute Fanfarr.Diagnostics.routine_web?("POST /settings")
    end

    test "anything the app itself logged is kept" do
      refute Fanfarr.Diagnostics.routine_web?("Plex is serving /tv2/X/theme.mp3 for X")
      refute Fanfarr.Diagnostics.routine_web?("loudness -16.5 -> -14.5 LUFS")
      refute Fanfarr.Diagnostics.routine_web?(nil)
    end
  end
end
