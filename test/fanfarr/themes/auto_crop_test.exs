defmodule Fanfarr.Themes.AutoCropTest do
  @moduledoc """
  Choosing the snippet: the viewership graph first, the audio when there is no
  graph, and the arithmetic the page quotes before anything is written.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  alias Fanfarr.Themes.AutoCrop
  alias Fanfarr.Themes.MostReplayed

  setup :verify_on_exit!

  describe "the most-replayed graph" do
    # A hundred two-second buckets over a 200s track with attention
    # concentrated mid-track, which is the shape a real graph has.
    defp markers do
      for index <- 0..99 do
        %{
          start_time: index * 2.0,
          end_time: index * 2.0 + 2.0,
          value: if(index in 30..44, do: 1.0, else: 0.2)
        }
      end
    end

    test "it picks the window the graph says people watch" do
      assert {:ok, window} = MostReplayed.best_window(markers(), 30_000)

      # The plateau is buckets 30..44, which is 60s..90s.
      assert window.start_ms >= 60_000
      assert window.end_ms <= 90_000
      assert window.score > 0.9
    end

    test "the window is exactly as long as it was asked for" do
      assert {:ok, window} = MostReplayed.best_window(markers(), 30_000)
      assert window.end_ms - window.start_ms == 30_000
    end

    test "a graph that is absent, empty or unusable is not a suggestion" do
      assert MostReplayed.best_window([], 30_000) == :no_signal
      assert MostReplayed.best_window(nil, 30_000) == :no_signal
      assert MostReplayed.best_window([%{start_time: nil, end_time: nil}], 30_000) == :no_signal
    end

    test "a target longer than the track is not a window" do
      # Ten buckets is 20s of graph; asking for 60s of it must not invent a
      # window that runs off the end.
      short = Enum.take(markers(), 10)
      assert MostReplayed.best_window(short, 60_000) == :no_signal
    end
  end

  describe "what the page quotes" do
    test "a snippet's cost, at the bitrate the writer uses" do
      assert AutoCrop.projected_bytes(30_000) == 720_000
      assert AutoCrop.projected_bytes(30_000, 128_000) == 480_000
      # The default target, which is what the page quotes in practice.
      assert AutoCrop.projected_bytes(90_000) == 2_160_000
    end

    test "the target length is a setting with a default" do
      # Ninety seconds: the piece, not a fragment of it.
      assert AutoCrop.target_ms() == 90_000
    end

    test "the operator's setting wins" do
      Fanfarr.Settings.put_setting!("auto_crop_target_ms", "45000")

      assert AutoCrop.target_ms() == 45_000
    end

    test "a setting that is not a number falls back to the default" do
      # A half-typed value in the settings field must not stop the feature.
      Fanfarr.Settings.put_setting!("auto_crop_target_ms", "ninety seconds")

      assert AutoCrop.target_ms() == 90_000
    end
  end

  describe "an item whose theme has a graph" do
    setup do
      section =
        Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

      item =
        Fanfarr.Library.sync_media_item_from_plex!(%{
          plex_rating_key: "101",
          section_id: section.id,
          title: "One Piece",
          kind: :show
        })

      # The pick is stored by its own action, the way the UI stores it: sync
      # only accepts what Plex reported.
      item =
        Fanfarr.Library.set_manual_theme!(item, %{
          manual_theme_url: "https://www.youtube.com/watch?v=abc12345678",
          manual_theme_title: "One Piece"
        })

      %{item: item}
    end

    test "the graph decides, and the audio is never touched", %{item: item} do
      markers =
        for index <- 0..99,
            do: %{start_time: index * 2.0, end_time: index * 2.0 + 2.0, value: 0.1}

      loud = List.replace_at(markers, 40, %{start_time: 80.0, end_time: 82.0, value: 1.0})

      expect(Fanfarr.ThemeDownloaderMock, :heatmap, fn url ->
        assert url == "https://www.youtube.com/watch?v=abc12345678"
        {:ok, loud}
      end)

      assert {:ok, suggestion} = AutoCrop.suggest(item, target_ms: 20_000)
      assert suggestion.source == :most_replayed
      assert suggestion.start_ms >= 78_000
      assert suggestion.end_ms - suggestion.start_ms == 20_000
    end

    test "no graph means the audio is asked instead", %{item: item} do
      expect(Fanfarr.ThemeDownloaderMock, :heatmap, fn _url -> {:error, :no_heatmap} end)

      # The audio has to be fetched to analyse it. Refusing the fetch is the
      # honest end of the ladder: an error value, not a crash and not a
      # silently invented window.
      stub(Fanfarr.ThemeDownloaderMock, :download_source, fn _url, _dir ->
        {:error, :unavailable}
      end)

      assert {:error, _reason} = AutoCrop.suggest(item, target_ms: 20_000)
    end
  end

  describe "an item with no theme at all" do
    test "it says so rather than guessing" do
      section =
        Fanfarr.Library.sync_section_from_plex!(%{plex_key: "2", title: "TV", kind: :show})

      item =
        Fanfarr.Library.sync_media_item_from_plex!(%{
          plex_rating_key: "202",
          section_id: section.id,
          title: "Nothing",
          kind: :show
        })

      assert {:error, :no_themerrdb_entry} = AutoCrop.suggest(item)
    end
  end

  describe "the audio itself, when there is no graph" do
    @describetag :requires_ffmpeg

    # 90 seconds: quiet, then loud, then quiet. To something that cannot hear,
    # that is a chorus in the middle.
    defp track do
      dir = Path.join(System.tmp_dir!(), "fanfarr-crop-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "track.mp3")

      # A list rather than a ~w sigil: the filter expression contains quotes
      # and parentheses, and ffmpeg wants the single quotes kept so the colons
      # inside the expression are not read as option separators.
      args = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=90",
        "-af",
        "volume='if(between(t,30,60),1,0.05)':eval=frame",
        "-c:a",
        "libmp3lame",
        path
      ]

      {_out, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)

      on_exit(fn -> File.rm_rf(dir) end)
      path
    end

    test "it picks the loud stretch" do
      assert {:ok, suggestion} = AutoCrop.suggest_from_audio(track(), target_ms: 20_000)

      assert suggestion.source == :audio
      assert suggestion.end_ms - suggestion.start_ms == 20_000

      # Inside the loud minute, allowing for the two-second boundary snap that
      # lands the cut on a quiet frame.
      assert suggestion.start_ms >= 28_000
      assert suggestion.start_ms <= 42_000
    end

    test "a track shorter than the target is left alone entirely" do
      # Not clamped and not partially cropped: there is nothing to save.
      assert AutoCrop.suggest_from_audio(track(), target_ms: 120_000) == :no_suggestion
    end

    test "a marginal crop is left alone when the minimum says so" do
      # 90 seconds against a 70-second target saves twenty seconds for a
      # generation of lossy loss, so a minimum above the track declines it.
      assert AutoCrop.suggest_from_audio(track(), target_ms: 70_000, min_ms: 105_000) ==
               :no_suggestion
    end

    test "and the same track is cropped when the minimum allows" do
      # The default minimum is the crop length itself, so 90 seconds against a
      # 70-second target is worth doing unless told otherwise.
      assert {:ok, suggestion} = AutoCrop.suggest_from_audio(track(), target_ms: 70_000)
      assert suggestion.end_ms - suggestion.start_ms == 70_000
    end
  end
end
