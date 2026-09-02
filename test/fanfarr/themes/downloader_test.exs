defmodule Fanfarr.Themes.DownloaderTest do
  use ExUnit.Case, async: true

  alias Fanfarr.Themes.Downloader
  alias Fanfarr.Themes.Downloader.YtDlp

  describe "classify_failure/1" do
    # Verbatim from a live run. yt-dlp says "This video is not available" here,
    # not "Video unavailable" -- the pattern only had the latter, so this came
    # back as a raw exit code and the queue retried a dead video five times.
    @observed """
    [youtube] Extracting URL: https://www.youtube.com/watch?v=HeOOgQVmi8o
    [youtube] HeOOgQVmi8o: Downloading webpage
    [youtube] HeOOgQVmi8o: Downloading visionos player API JSON
    ERROR: [youtube] HeOOgQVmi8o: This video is not available
    """

    test "the wording a live yt-dlp actually produced reads as gone" do
      assert YtDlp.classify_failure(@observed) == :unavailable
    end

    test "yt-dlp's other ways of saying gone" do
      for output <- [
            "ERROR: Video unavailable",
            "ERROR: Private video. Sign in if you've been granted access",
            "ERROR: This video has been removed by the uploader",
            "ERROR: The account associated with this video has been terminated"
          ] do
        assert YtDlp.classify_failure(output) == :unavailable, output
      end
    end

    test "restrictions are told apart from removals" do
      assert YtDlp.classify_failure("ERROR: Sign in to confirm your age") == :age_restricted

      assert YtDlp.classify_failure(
               "ERROR: The uploader has not made this video available in your country"
             ) ==
               :geo_blocked
    end

    test "a bare \"age\" inside another word is not an age restriction" do
      # /age/ alone matched "message", "package", "storage".
      assert {:exit, 1, _} = YtDlp.classify_failure("ERROR: unable to parse the storage message")
    end

    test "anything unrecognised keeps its output rather than being guessed at" do
      assert {:exit, 1, output} = YtDlp.classify_failure("ERROR: something new and strange")
      assert output =~ "something new and strange"
    end
  end

  describe "youtube_url?/1" do
    test "accepts the hosts YouTube actually uses" do
      for url <- [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "http://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
          ] do
        assert Downloader.youtube_url?(url), url
      end
    end

    test "rejects everything else, including what yt-dlp would happily accept" do
      # These come from a third-party database and a text box. yt-dlp takes
      # local paths and other protocols, so the allowlist is the guard.
      for url <- [
            "/etc/passwd",
            "file:///etc/passwd",
            "ftp://youtube.com/x",
            "https://evil.example/?u=youtube.com",
            "https://notyoutube.com/watch?v=x",
            "",
            nil,
            42
          ] do
        refute Downloader.youtube_url?(url), inspect(url)
      end
    end
  end

  describe "youtube_id/1" do
    test "extracts the id from the common URL shapes" do
      for url <- [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/embed/dQw4w9WgXcQ"
          ] do
        assert Downloader.youtube_id(url) == "dQw4w9WgXcQ", url
      end
    end

    test "nothing for a malformed id, since it would go straight into an iframe src" do
      assert Downloader.youtube_id("https://www.youtube.com/watch?v=<script>") == nil
      assert Downloader.youtube_id("https://www.youtube.com/") == nil
      assert Downloader.youtube_id(nil) == nil
    end
  end

  describe "YtDlp.parse_search/1" do
    test "reads one JSON object per line into hits" do
      output =
        ~s({"id":"abc12345678","title":"One Piece OP 1","channel":"Toei","duration":92.5,"view_count":1200,"thumbnails":[{"url":"lo.jpg"},{"url":"hi.jpg"}]}
{"id":"def12345678","title":"Other","uploader":"Someone","thumbnail":"one.jpg"}
)

      assert [first, second] = YtDlp.parse_search(output)
      assert first.id == "abc12345678"
      assert first.url == "https://www.youtube.com/watch?v=abc12345678"
      assert first.channel == "Toei"
      assert first.duration == 92.5
      assert first.view_count == 1200
      assert first.thumbnail == "hi.jpg"
      assert second.channel == "Someone"
      assert second.thumbnail == "one.jpg"
      assert second.duration == nil
    end

    test "a warning line on stdout does not lose the results around it" do
      output = "WARNING: something\n" <> ~s({"id":"abc12345678","title":"x"}) <> "\n"
      assert [%{id: "abc12345678"}] = YtDlp.parse_search(output)
    end
  end

  test "search with a blank query is empty without running anything" do
    assert {:ok, []} = YtDlp.search("   ", 5)
  end

  test "without the binary, search and version say so rather than crashing" do
    # yt-dlp is not installed in this environment; that is the case under test.
    if System.find_executable("yt-dlp") do
      :ok
    else
      assert {:error, :not_installed} = YtDlp.version()
      assert {:error, :not_installed} = YtDlp.search("one piece", 3)
    end
  end
end
