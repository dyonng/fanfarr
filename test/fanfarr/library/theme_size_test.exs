defmodule Fanfarr.Library.ThemeSizeTest do
  @moduledoc """
  How much disk Fanfarr's own writes occupy, per item.

  The number the library table lists and the dashboard totals, exercised
  against a real database rather than the calculation in isolation: the point
  of deriving it is that it stays true to the append-only log underneath, and
  the interesting cases are all about which row wins.
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

  defp size(item) do
    item |> Ash.load!(:theme_size) |> Map.fetch!(:theme_size)
  end

  test "an item Fanfarr never wrote for is nothing", %{section: section} do
    assert size(item(section, %{})) == 0
  end

  test "a succeeded application reports the file it wrote", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, bytes: 1_500_000})

    assert size(item) == 1_500_000
  end

  test "a re-apply is the newest file, not both of them", %{section: section} do
    # The reason this is not SUM(bytes): the log is append-only, so a retry is
    # a second row, and adding them up would bill one theme twice.
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, bytes: 1_500_000})
    apply_theme(item, %{status: :succeeded, bytes: 2_500_000})

    assert size(item) == 2_500_000
  end

  test "a failed attempt leaves the last written size standing", %{section: section} do
    # Writer stages to a temp name and renames, so a failure never
    # half-replaces a theme that is already there. The file survives, so the
    # size has to.
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, bytes: 1_500_000})
    apply_theme(item, %{status: :failed, error: "yt-dlp died"})

    assert size(item) == 1_500_000
  end

  test "a failed first attempt has no size to carry forward", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :failed, error: "no source for this one"})

    assert size(item) == 0
  end

  test "a removal is nothing on disk", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, bytes: 1_500_000})
    apply_theme(item, %{status: :removed})

    assert size(item) == 0
  end

  test "an apply after a removal counts again", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, bytes: 1_500_000})
    apply_theme(item, %{status: :removed})
    apply_theme(item, %{status: :succeeded, bytes: 900_000})

    assert size(item) == 900_000
  end

  test "a pending intent is not a size", %{section: section} do
    # `record_intent` is written before the upload is attempted, so a crash
    # mid-apply leaves a row with no bytes at all.
    item = item(section, %{})
    apply_theme(item, %{status: :pending})

    assert size(item) == 0
  end

  test "the batch gives one value per item, not one per row", %{section: section} do
    one = item(section, %{title: "One"})
    two = item(section, %{title: "Two"})
    apply_theme(one, %{status: :succeeded, bytes: 1000})
    apply_theme(one, %{status: :succeeded, bytes: 1000})
    apply_theme(two, %{status: :succeeded, bytes: 2000})

    sizes =
      MediaItem
      |> Ash.Query.load(:theme_size)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.title, &1.theme_size})

    assert sizes == %{"One" => 1000, "Two" => 2000}
  end

  test "an item with no rows at all reads as nothing, not as a failure", %{section: section} do
    # The calculation runs for the whole loaded batch, so an item whose id
    # appears in no row has to be answered for rather than dropped.
    quiet = item(section, %{title: "Quiet"})
    apply_theme(item(section, %{title: "Loud"}), %{status: :succeeded, bytes: 4096})

    sizes =
      MediaItem
      |> Ash.Query.load(:theme_size)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.title, &1.theme_size})

    assert sizes["Quiet"] == 0
    assert Map.fetch!(sizes, quiet.title) == 0
    assert sizes["Loud"] == 4096
  end
end
