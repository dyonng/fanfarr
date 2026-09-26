defmodule Fanfarr.Library.ExcludedTest do
  @moduledoc """
  "Never touch this title": the flag, and what it takes a title out of.

  The distinction under test is the one the crop switch makes as well -- excluded
  means nothing unattended is expected of the title, not that an operator may
  not act on it. Both halves of that are asserted, because a flag that quietly
  blocked manual work would be a different feature from the one the roadmap
  asked for.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Library
  alias Fanfarr.Overview

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

    Library.sync_media_item_from_plex!(%{
      plex_rating_key: "102",
      section_id: section.id,
      title: "Fleabag",
      kind: :show
    })

    %{item: item, section: section}
  end

  test "off by default, and settable", %{item: item} do
    refute item.excluded

    assert {:ok, updated} = Library.set_media_item_excluded(item, %{excluded: true})
    assert updated.excluded

    # And it survives the round trip, so the next sync does not undo it. The
    # sync's own action does not accept the field -- that is the point.
    reloaded = Library.get_media_item!(item.id)
    assert reloaded.excluded
  end

  test "an excluded title stops being a task, and stays in the library", %{item: item} do
    assert Overview.load().totals.missing == 2
    assert Overview.load().excluded == 0

    {:ok, _} = Library.set_media_item_excluded(item, %{excluded: true})

    dashboard = Overview.load()

    # Out of the count, because it is not something to go and do.
    assert dashboard.totals.missing == 1
    # Still in the library, and reported as excluded rather than gone.
    assert dashboard.totals.total == 2
    assert dashboard.excluded == 1
  end

  test "a sync does not resurrect it", %{item: item, section: section} do
    {:ok, _} = Library.set_media_item_excluded(item, %{excluded: true})

    # Exactly what the section sync sends, which is what would silently clear a
    # field it accepted.
    Library.sync_media_item_from_plex!(%{
      plex_rating_key: "101",
      section_id: section.id,
      title: "One Piece",
      kind: :show,
      year: 1999
    })

    assert Library.get_media_item!(item.id).excluded
  end

  test "an action aimed at it by hand still works", %{item: item} do
    {:ok, _} = Library.set_media_item_excluded(item, %{excluded: true})

    assert {:ok, themed} =
             Library.set_manual_theme(item, %{
               manual_theme_url: "https://youtu.be/abcdefghijk",
               manual_theme_title: "One Piece OP 1"
             })

    assert themed.manual_theme_url == "https://youtu.be/abcdefghijk"
  end
end
