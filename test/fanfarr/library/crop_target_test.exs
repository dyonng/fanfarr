defmodule Fanfarr.Library.CropTargetTest do
  @moduledoc """
  One title's own crop length: the override, and what reads it.

  The distinction under test is the one the crop switch makes as well -- a set
  length is an explicit instruction for this title, not a new default, so a
  blank means the global target and a sync never touches it.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Library
  alias Fanfarr.Themes.AutoCrop

  setup do
    section =
      Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

    item =
      Library.sync_media_item_from_plex!(%{
        plex_rating_key: "101",
        section_id: section.id,
        title: "One Piece",
        kind: :show
      })

    %{item: item}
  end

  test "unset by default, and the global target answers", %{item: item} do
    assert is_nil(item.crop_target_ms)
    assert AutoCrop.target_for(item) == AutoCrop.target_ms()
  end

  test "set, round-trips, and moves the target", %{item: item} do
    assert {:ok, updated} = Library.set_crop_target(item, %{crop_target_ms: 45_000})
    assert updated.crop_target_ms == 45_000
    assert AutoCrop.target_for(updated) == 45_000

    assert Library.get_media_item!(item.id).crop_target_ms == 45_000
  end

  test "nil clears back to the global target", %{item: item} do
    {:ok, set} = Library.set_crop_target(item, %{crop_target_ms: 45_000})
    assert {:ok, cleared} = Library.set_crop_target(set, %{crop_target_ms: nil})
    assert is_nil(cleared.crop_target_ms)
    assert AutoCrop.target_for(cleared) == AutoCrop.target_ms()
  end

  test "bounds reject what the settings page would not allow", %{item: item} do
    assert {:error, _} = Library.set_crop_target(item, %{crop_target_ms: 4_000})
    assert {:error, _} = Library.set_crop_target(item, %{crop_target_ms: 901_000})
    assert is_nil(Library.get_media_item!(item.id).crop_target_ms)
  end

  test "a later sync does not undo it", %{item: item} do
    {:ok, _} = Library.set_crop_target(item, %{crop_target_ms: 45_000})

    Library.sync_media_item_from_plex!(%{
      plex_rating_key: "101",
      section_id: item.section_id,
      title: "One Piece",
      kind: :show
    })

    assert Library.get_media_item!(item.id).crop_target_ms == 45_000
  end
end
