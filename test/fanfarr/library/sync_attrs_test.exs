defmodule Fanfarr.Library.SyncAttrsTest do
  @moduledoc """
  The one mapping both writers read. A field the parser produces that this
  drops is a title synced without it on one path and with it on the other --
  the season count bug, then the directors bug -- so this pins the whole
  translation, not just the fields that have bitten so far.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Library.SyncAttrs

  defp fresh(over \\ %{}) do
    Map.merge(
      %{
        rating_key: "500",
        guid: "plex://movie/abc",
        title: "The Dark Knight",
        year: 2008,
        kind: :movie,
        path: "/movies1/The Dark Knight (2008)/movie.mkv",
        imdb_id: "tt0468569",
        tmdb_id: "155",
        tvdb_id: nil,
        thumb: "/library/metadata/500/thumb/1",
        theme: "/library/metadata/500/theme/1",
        critic_score: 9.4,
        critic_score_source: "rottentomatoes",
        audience_score: 8.0,
        audience_score_source: "themoviedb",
        studio: "Warner Bros. Pictures",
        collections: ["Batman Collection"],
        directors: ["Christopher Nolan"],
        added_at: ~U[2024-01-01 00:00:00Z],
        season_count: nil
      },
      over
    )
  end

  test "every parsed field lands on its row key" do
    assert SyncAttrs.for_item(fresh()) == %{
             plex_rating_key: "500",
             guid: "plex://movie/abc",
             title: "The Dark Knight",
             year: 2008,
             kind: :movie,
             plex_path: "/movies1/The Dark Knight (2008)/movie.mkv",
             imdb_id: "tt0468569",
             tmdb_id: "155",
             tvdb_id: nil,
             plex_thumb_key: "/library/metadata/500/thumb/1",
             critic_score: 9.4,
             critic_score_source: "rottentomatoes",
             audience_score: 8.0,
             audience_score_source: "themoviedb",
             studio: "Warner Bros. Pictures",
             collections: ["Batman Collection"],
             directors: ["Christopher Nolan"],
             plex_theme_url: "/library/metadata/500/theme/1",
             added_at: ~U[2024-01-01 00:00:00Z],
             season_count: nil
           }
  end

  test "section_id is the caller's to add, never the mapping's to guess" do
    refute Map.has_key?(SyncAttrs.for_item(fresh()), :section_id)
  end
end
