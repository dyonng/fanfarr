defmodule Fanfarr.Themes.ThemerrEntryTest do
  use Fanfarr.DataCase, async: true

  alias Fanfarr.Themes.ThemerrEntry

  defp record(attrs) do
    ThemerrEntry
    |> Ash.Changeset.for_create(
      :record_lookup,
      Map.merge(%{item_type: :tv_shows, database: :themoviedb, external_id: "1396"}, attrs)
    )
    |> Ash.create!()
  end

  test "a hit stores the theme and its change key" do
    entry =
      record(%{
        found: true,
        youtube_theme_url: "https://www.youtube.com/watch?v=ilfYnhXD-bE",
        youtube_theme_edited: 1_706_845_643
      })

    assert entry.found
    assert entry.youtube_theme_edited == 1_706_845_643
    assert entry.fetched_at
  end

  test "a miss is cached too, so absent titles are not re-requested every cycle" do
    entry = record(%{found: false})

    refute entry.found
    assert entry.fetched_at
  end

  test "looking up the same title again updates in place rather than duplicating" do
    first = record(%{found: false})
    second = record(%{found: true, youtube_theme_url: "https://y.t/x", youtube_theme_edited: 42})

    assert first.id == second.id
    assert second.found
    assert Ash.count!(ThemerrEntry) == 1
  end

  test "the same id under a different database is a different entry" do
    record(%{database: :themoviedb, external_id: "1396"})
    record(%{database: :imdb, external_id: "1396"})

    assert Ash.count!(ThemerrEntry) == 2
  end

  test "a movie and a show sharing an id do not collide" do
    record(%{item_type: :tv_shows, external_id: "550"})
    record(%{item_type: :movies, external_id: "550"})

    assert Ash.count!(ThemerrEntry) == 2
  end

  test "stale entries can be found by age" do
    # Freshly recorded, so not stale under any sane TTL.
    record(%{found: true})

    assert [] = ThemerrEntry |> Ash.Query.for_read(:stale, %{ttl_seconds: 3600}) |> Ash.read!()

    # An entry fetched two days ago is stale under a one-day TTL. Written
    # directly rather than by shifting the TTL, so the test exercises the
    # comparison the sync job actually makes.
    two_days_ago = DateTime.add(DateTime.utc_now(), -2, :day)

    ThemerrEntry
    |> Ash.Changeset.for_create(:create, %{
      item_type: :movies,
      database: :imdb,
      external_id: "tt0137523",
      found: true,
      fetched_at: two_days_ago
    })
    |> Ash.create!()

    assert [stale] =
             ThemerrEntry |> Ash.Query.for_read(:stale, %{ttl_seconds: 86_400}) |> Ash.read!()

    assert stale.external_id == "tt0137523"
  end
end
