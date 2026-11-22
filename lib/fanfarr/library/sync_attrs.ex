defmodule Fanfarr.Library.SyncAttrs do
  @moduledoc """
  One mapping from a parsed Plex item to the row it mirrors.

  Both writers -- the section sync and the single-item refresh -- read
  through this, so a field Plex parses can no longer arrive on one path and
  silently miss the other. That happened twice: season count, then directors.
  Each time the parser had its own test and the write had its own fixture,
  and nothing joined the two.

  Only translations nobody can argue with live here. Anything needing
  judgement -- the theme origin lookup, the collections merge, a path that
  falls back to the stored one -- stays at the call site, next to the
  reason it exists.
  """

  @doc """
  The row attributes that are pure translations of the parsed item.

  Keys are row names, so the result merges straight into the sync action's
  arguments; the caller overrides whatever needs judgement. `section_id`
  is deliberately absent: neither parser produces it, and both callers
  know it already.
  """
  @spec for_item(map()) :: map()
  def for_item(fresh) do
    %{
      plex_rating_key: fresh.rating_key,
      guid: fresh.guid,
      title: fresh.title,
      year: fresh.year,
      kind: fresh.kind,
      plex_path: fresh.path,
      imdb_id: fresh.imdb_id,
      tmdb_id: fresh.tmdb_id,
      tvdb_id: fresh.tvdb_id,
      plex_thumb_key: fresh.thumb,
      critic_score: fresh.critic_score,
      critic_score_source: fresh.critic_score_source,
      audience_score: fresh.audience_score,
      audience_score_source: fresh.audience_score_source,
      studio: fresh.studio,
      collections: fresh.collections,
      directors: fresh.directors,
      plex_theme_url: fresh.theme,
      added_at: fresh.added_at,
      season_count: fresh.season_count
    }
  end
end
