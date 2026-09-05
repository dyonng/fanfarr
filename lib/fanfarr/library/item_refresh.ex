defmodule Fanfarr.Library.ItemRefresh do
  @moduledoc """
  Re-reads one item from Plex, for the Refresh button on its page.

  The scheduled sync walks a whole section, which is the right shape for
  "what changed across the library" and the wrong one for "I just renamed
  this one thing in Plex and want to see it here". This asks about a single
  ratingKey and writes the answer through the same `:sync_from_plex` action
  the section sync uses, so there is one definition of what Plex owns.

  ## What it will not overwrite

  Two fields are merged rather than replaced, because Plex's single-item
  response is a less complete source than the section sync for each of them
  and a refresh that *lost* information would be worse than no refresh:

    * **plex_path** -- the listing does not always report one, and the sync
      goes to some length to recover it. A response without a path leaves the
      stored one alone.

    * **collections** -- agent-built collections (the "Star Wars Collection"
      sort Plex assembles from TMDB) are missing from the per-item Collection
      tags on the reference server, which is why the sync reads them from the
      section's own collections endpoint instead. Doing that here would mean
      a request per collection to refresh one title, so an empty answer is
      treated as "this endpoint does not know" rather than "it belongs to
      none". The trade is that removing an item from a collection in Plex
      shows up on the next section sync rather than on this button.
  """

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Plex.Client

  @type reason :: :plex_not_configured | :not_found | term()

  @doc """
  Pulls this item's metadata and theme state from Plex and stores it.

  Returns the reloaded item. A theme lookup that fails degrades to `:unknown`
  rather than failing the refresh -- the same trade the section sync makes,
  since a missing origin is a less informative page and not a broken one.
  """
  @spec refresh(Library.MediaItem.t()) :: {:ok, Library.MediaItem.t()} | {:error, reason()}
  def refresh(item) do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, fresh} <- Client.impl().item(config, item.plex_rating_key) do
      {origin, agent} = origin(config, fresh)

      Library.sync_media_item_from_plex!(%{
        plex_rating_key: fresh.rating_key,
        section_id: item.section_id,
        guid: fresh.guid,
        title: fresh.title,
        year: fresh.year,
        kind: fresh.kind,
        plex_path: presence(fresh.path) || item.plex_path,
        imdb_id: fresh.imdb_id,
        tmdb_id: fresh.tmdb_id,
        tvdb_id: fresh.tvdb_id,
        plex_thumb_key: fresh.thumb,
        critic_score: fresh.critic_score,
        critic_score_source: fresh.critic_score_source,
        audience_score: fresh.audience_score,
        audience_score_source: fresh.audience_score_source,
        studio: fresh.studio,
        collections: merge_collections(fresh.collections, item.collections),
        plex_theme_url: fresh.theme,
        plex_theme_origin: origin,
        plex_theme_agent: agent,
        added_at: fresh.added_at
      })

      {:ok, Library.get_media_item!(item.id, load: [:theme_status, :section])}
    end
  end

  # Only asked for when the listing says there is a theme at all: "no theme"
  # is its own answer and does not need a round trip to confirm.
  defp origin(config, %{theme: theme} = fresh) when is_binary(theme) and theme != "" do
    case Client.impl().themes(config, fresh.rating_key) do
      {:ok, themes} ->
        case Fanfarr.Plex.ThemeOrigin.selected(themes) do
          nil -> {:unknown, nil}
          selected -> {selected.origin, selected[:agent]}
        end

      {:error, reason} ->
        Logger.warning(
          "[fanfarr] could not read the theme origin for #{fresh.title} (#{inspect(reason)})"
        )

        {:unknown, nil}
    end
  end

  defp origin(_config, _fresh), do: {:none, nil}

  defp merge_collections([], existing), do: existing
  defp merge_collections(fresh, _existing), do: fresh

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
