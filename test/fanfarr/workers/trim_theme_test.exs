defmodule Fanfarr.Workers.TrimThemeTest do
  @moduledoc """
  Finding a crop for an item's current theme, and handing the write on.

  The write itself is `ApplyTheme`'s and is tested there; what is tested here is
  the decision -- which items get a crop, and which are left alone.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  alias Fanfarr.Library
  alias Fanfarr.Workers.TrimTheme

  setup :verify_on_exit!

  setup do
    section =
      Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

    %{section: section}
  end

  defp item(section, over \\ %{}) do
    Library.sync_media_item_from_plex!(
      Map.merge(
        %{
          plex_rating_key: "rk-#{:erlang.unique_integer([:positive])}",
          section_id: section.id,
          title: "One Piece",
          kind: :show,
          imdb_id: "tt0388629",
          plex_path: "/tv/One Piece (1999)"
        },
        over
      )
    )
  end

  # A hundred buckets over four seconds, twenty of them carrying the
  # attention. The timeline is the graph's own, so nothing has to be downloaded
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

  defp perform(item) do
    TrimTheme.perform(%Oban.Job{args: %{"media_item_id" => item.id}})
  end

  defp queued_workers do
    Fanfarr.Repo.all(Oban.Job) |> Enum.map(& &1.worker)
  end

  test "a suggestion becomes a crop, and the write is queued", %{section: section} do
    Fanfarr.Settings.put_setting!("auto_crop_target_ms", "2000")

    item =
      section
      |> item()
      |> Library.set_manual_theme!(%{
        manual_theme_url: "https://www.youtube.com/watch?v=trimme00000"
      })

    expect(Fanfarr.ThemeDownloaderMock, :heatmap, fn _url -> {:ok, markers()} end)

    assert {:ok, %Oban.Job{}} = perform(item)

    written = Library.get_media_item!(item.id)

    # A window of the configured length, wherever the graph put it.
    assert is_integer(written.theme_start_ms)
    assert written.theme_end_ms - written.theme_start_ms == 2_000

    # And faded the way the trimmer would have faded it by hand: 250 in, 500
    # out, the hook's own fallbacks.
    assert written.theme_fade_in_ms == 250
    assert written.theme_fade_out_ms == 500

    # The crop is only a decision until ApplyTheme writes it.
    assert "Fanfarr.Workers.ApplyTheme" in queued_workers()
  end

  test "a crop the operator chose is left alone", %{section: section} do
    item =
      section
      |> item()
      |> Library.set_theme_trim!(%{
        theme_start_ms: 1_000,
        theme_end_ms: 31_000,
        theme_fade_in_ms: 500,
        theme_fade_out_ms: 500
      })

    assert perform(item) == {:cancel, :already_cropped}

    # Nothing was queued either, which is what makes this safe to press twice:
    # the second run over the same library writes nothing.
    refute "Fanfarr.Workers.ApplyTheme" in queued_workers()

    kept = Library.get_media_item!(item.id)
    assert kept.theme_start_ms == 1_000
    assert kept.theme_end_ms == 31_000
  end

  test "a disabled feature cancels rather than guessing anyway", %{section: section} do
    Fanfarr.Settings.put_setting!("auto_crop_enabled", "false")
    item = item(section)

    assert perform(item) == {:cancel, :crop_disabled}
    refute "Fanfarr.Workers.ApplyTheme" in queued_workers()
  end

  test "an item with no theme to crop is skipped", %{section: section} do
    # Nothing knows of a theme for it, so there is no window to find. A
    # cancellation rather than a failure: retrying will not produce one.
    assert {:cancel, _reason} = perform(item(section))
    refute "Fanfarr.Workers.ApplyTheme" in queued_workers()
  end
end
