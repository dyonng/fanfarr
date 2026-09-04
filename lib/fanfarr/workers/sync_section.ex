defmodule Fanfarr.Workers.SyncSection do
  @moduledoc """
  Mirrors every item in one Plex section into the library.

  Writes are chunked so the sync yields the SQLite write lock between batches
  rather than holding it for the whole section -- the dashboard stays readable
  while 750 shows sync. The Plex reads happen entirely before any write, per
  the rule that no transaction spans HTTP.

  ## Why there is a second round of Plex reads

  The section listing says *whether* an item has a theme but not where it came
  from, and the difference is the product: a show carrying Plex's own stock
  theme looks identical to one someone chose deliberately. Origin only comes
  from `/library/metadata/<id>/themes`, which is one request per item.

  So we ask only about items the listing already says have a theme. On the
  reference library that is 396 requests against 2,564 items -- the 2,168 with
  no theme need no round trip, since "no theme" is its own answer. They run
  concurrently and a failure degrades to `:unknown` rather than failing the
  sync, because a missing origin is a worse-looking dashboard, not a broken one.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 300, keys: [:section_id], states: [:available, :scheduled, :executing]]

  require Logger

  alias Fanfarr.Library

  # Concurrency is deliberately modest: this is someone's media server, often
  # the same box that is transcoding, and a sync is background work. Shared by
  # the origin and the path lookups, which have the same shape.
  @origin_concurrency 8
  @origin_timeout 15_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"section_id" => section_id}}) do
    section = Library.get_section!(section_id)

    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, items} <- Fanfarr.Plex.Client.impl().items(config, section.plex_key) do
      origins = origins(config, items)
      paths = paths(config, items, section)

      items
      |> Enum.chunk_every(100)
      |> Enum.each(fn chunk ->
        Enum.each(chunk, fn item ->
          {origin, agent} = Map.get(origins, item.rating_key, {:none, nil})

          Library.sync_media_item_from_plex!(%{
            plex_rating_key: item.rating_key,
            section_id: section.id,
            guid: item.guid,
            title: item.title,
            year: item.year,
            kind: item.kind,
            plex_path: Map.get(paths, item.rating_key),
            imdb_id: item.imdb_id,
            tmdb_id: item.tmdb_id,
            tvdb_id: item.tvdb_id,
            plex_thumb_key: item.thumb,
            critic_score: item.critic_score,
            critic_score_source: item.critic_score_source,
            audience_score: item.audience_score,
            audience_score_source: item.audience_score_source,
            plex_theme_url: item.theme,
            plex_theme_origin: origin,
            plex_theme_agent: agent,
            added_at: item.added_at
          })
        end)
      end)

      prune(section, items)

      Phoenix.PubSub.broadcast(Fanfarr.PubSub, "library", {:section_synced, section.id})
      :ok
    else
      {:error, :plex_not_configured} -> {:cancel, :plex_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  # Items we hold that Plex has stopped listing.
  #
  # Rename a folder and Plex does not update the item -- it drops the old one
  # and adds a new one under a fresh ratingKey. An additive sync therefore
  # leaves the library showing both, which is what "The Dark Knight" appearing
  # twice was: one row for the folder as it used to be named, one for its
  # replacement.
  #
  # Marked, not deleted, because the theme application log points at these rows
  # with no cascade, so SQLite *refuses* the delete for precisely the items
  # worth keeping -- anything Fanfarr has ever applied a theme to. See
  # MediaItem's :mark_missing_from_plex.
  defp prune(section, items) do
    listed = MapSet.new(items, & &1.rating_key)

    # An empty listing is not evidence that a library is empty. Plex returns
    # one while a scan is in progress, and a section whose storage is offline
    # reports no items rather than an error. Believing it would blank the
    # mirror -- and hide every item until the next successful sync.
    if MapSet.size(listed) == 0 do
      Logger.warning(
        "[fanfarr] Plex listed no items in section #{section.title}; " <>
          "nothing pruned, since an empty listing is more likely a scan in progress"
      )
    else
      section.id
      |> Library.present_media_items_in_section!()
      |> Enum.reject(&MapSet.member?(listed, &1.plex_rating_key))
      |> Enum.each(fn item ->
        Logger.info(
          "[fanfarr] Plex no longer lists #{item.title} (ratingKey #{item.plex_rating_key}); " <>
            "hiding it from the library"
        )

        Library.mark_media_item_missing!(item)
      end)
    end
  end

  # The listing gives a movie its file and is supposed to give a show a
  # Location. When it gives neither there is nothing to write a theme beside,
  # and the apply fails with :no_plex_path -- which is what happened on the
  # reference server for every show.
  #
  # So a missing path is asked for per item, and only for items that have no
  # path from the listing AND none already stored: a path does not change, so
  # this is a one-off cost per item rather than a per-sync one. Anything we
  # already knew survives a listing that stops reporting it.
  defp paths(config, items, section) do
    known =
      section.id
      |> Library.media_items_in_section!()
      |> Map.new(&{&1.plex_rating_key, presence(&1.plex_path)})

    needed =
      Enum.filter(items, fn item ->
        is_nil(presence(item.path)) and is_nil(Map.get(known, item.rating_key))
      end)

    fetched =
      needed
      |> Task.async_stream(
        fn item ->
          {item.rating_key,
           Fanfarr.Plex.Client.impl().item_path(config, item.rating_key, item.kind)}
        end,
        max_concurrency: @origin_concurrency,
        timeout: @origin_timeout,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, {rating_key, {:ok, path}}} -> [{rating_key, presence(path)}]
        {:ok, {rating_key, {:error, reason}}} -> log_missing(rating_key, reason)
        {:exit, _reason} -> []
      end)
      |> Map.new()

    Map.new(items, fn item ->
      resolved =
        presence(item.path) || Map.get(fetched, item.rating_key) ||
          Map.get(known, item.rating_key)

      {item.rating_key, resolved}
    end)
  end

  defp log_missing(rating_key, reason) do
    Logger.warning(
      "[fanfarr] Plex reports no path for ratingKey #{rating_key} (#{inspect(reason)}); " <>
        "a theme cannot be written for it"
    )

    []
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  defp origins(config, items) do
    items
    |> Enum.filter(&has_theme?/1)
    |> Task.async_stream(
      fn item -> {item.rating_key, origin_of(config, item)} end,
      max_concurrency: @origin_concurrency,
      timeout: @origin_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {rating_key, result}} -> [{rating_key, result}]
      # A task that timed out or crashed leaves the item at its previous
      # origin rather than taking the sync down with it.
      {:exit, _reason} -> []
    end)
    |> Map.new()
  end

  defp has_theme?(%{theme: theme}), do: is_binary(theme) and theme != ""
  defp has_theme?(_), do: false

  defp origin_of(config, item) do
    case Fanfarr.Plex.Client.impl().themes(config, item.rating_key) do
      {:ok, themes} ->
        case Fanfarr.Plex.ThemeOrigin.selected(themes) do
          nil -> {:unknown, nil}
          theme -> {theme.origin, theme[:agent]}
        end

      {:error, _reason} ->
        # The listing already told us a theme exists; we just cannot say whose.
        {:unknown, nil}
    end
  end
end
