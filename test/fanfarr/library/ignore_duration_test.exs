defmodule Fanfarr.Library.IgnoreDurationTest do
  @moduledoc """
  One title's escape from the download duration cap.

  Off by default and never touched by a sync: Plex knows nothing of this
  switch, so a rescan must not clear it.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Library

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

  test "off by default, settable, and round-trips", %{item: item} do
    refute item.ignore_duration_limit

    assert {:ok, updated} =
             Library.set_ignore_duration_limit(item, %{ignore_duration_limit: true})

    assert updated.ignore_duration_limit
    assert Library.get_media_item!(item.id).ignore_duration_limit
  end

  test "a later sync does not undo it", %{item: item} do
    {:ok, _} = Library.set_ignore_duration_limit(item, %{ignore_duration_limit: true})

    Library.sync_media_item_from_plex!(%{
      plex_rating_key: "101",
      section_id: item.section_id,
      title: "One Piece",
      kind: :show
    })

    assert Library.get_media_item!(item.id).ignore_duration_limit
  end
end
