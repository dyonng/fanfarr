defmodule Fanfarr.Library.ThemeDurationTest do
  @moduledoc """
  How long the theme Fanfarr wrote plays, per item.

  The same reading of the append-only log that `ThemeSize` uses, so the cases
  worth pinning are the same ones: which row wins, and what an absent length
  means. Exercised against a real database because the point of deriving it is
  that it stays true to the rows underneath.
  """
  use Fanfarr.DataCase, async: true

  alias Fanfarr.Library.MediaItem
  alias Fanfarr.Library.Section
  alias Fanfarr.Themes.ThemeApplication

  setup do
    section =
      Section
      |> Ash.Changeset.for_create(:create, %{
        plex_key: "1",
        title: "TV Shows",
        kind: :show,
        enabled: true
      })
      |> Ash.create!()

    %{section: section}
  end

  defp item(section, attrs) do
    MediaItem
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          plex_rating_key: "rk-#{System.unique_integer([:positive])}",
          title: "A Show",
          kind: :show,
          section_id: section.id
        },
        attrs
      )
    )
    |> Ash.create!()
  end

  defp apply_theme(item, attrs) do
    ThemeApplication
    |> Ash.Changeset.for_create(
      :record_outcome,
      Map.merge(
        %{
          media_item_id: item.id,
          source: :themerrdb,
          method: :api_upload,
          theme_url: "https://www.youtube.com/watch?v=abc"
        },
        attrs
      )
    )
    |> Ash.create!()
  end

  defp length_of(item) do
    item |> Ash.load!(:theme_duration) |> Map.fetch!(:theme_duration)
  end

  test "an item Fanfarr never wrote for has no length", %{section: section} do
    assert length_of(item(section, %{})) == nil
  end

  test "a succeeded application reports the length it recorded", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: 162_000})

    assert length_of(item) == 162_000
  end

  test "a re-apply is the newest length, not the longest", %{section: section} do
    # A trim makes a theme shorter, and the shorter one is what is on disk.
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: 162_000})
    apply_theme(item, %{status: :succeeded, duration_ms: 45_500})

    assert length_of(item) == 45_500
  end

  test "a failed attempt leaves the length of the file still on disk", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: 162_000})
    apply_theme(item, %{status: :failed, error: "yt-dlp died"})

    assert length_of(item) == 162_000
  end

  test "a skipped apply leaves it too", %{section: section} do
    # :skipped is the idempotency path: the intended theme was already applied,
    # so the file -- and its length -- are unchanged.
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: 162_000})
    apply_theme(item, %{status: :skipped})

    assert length_of(item) == 162_000
  end

  test "a removal has no length left", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: 162_000})
    apply_theme(item, %{status: :removed})

    assert length_of(item) == nil
  end

  test "a success that recorded no length keeps the one we had", %{section: section} do
    # Rows applied before the log recorded a length are still succeeded rows.
    # Blanking a fact we already hold would be worse than a stale one.
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: 162_000})
    apply_theme(item, %{status: :succeeded, bytes: 1024})

    assert length_of(item) == 162_000
  end

  test "a success with no length at all reads as unknown, not as zero",
       %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, duration_ms: nil, bytes: 1024})

    assert length_of(item) == nil
  end

  test "the batch gives one length per item", %{section: section} do
    one = item(section, %{title: "One"})
    two = item(section, %{title: "Two"})
    apply_theme(one, %{status: :succeeded, duration_ms: 1000})
    apply_theme(one, %{status: :succeeded, duration_ms: 2000})
    apply_theme(two, %{status: :succeeded, duration_ms: 3000})

    lengths =
      MediaItem
      |> Ash.Query.load(:theme_duration)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.title, &1.theme_duration})

    assert lengths == %{"One" => 2000, "Two" => 3000}
  end
end
