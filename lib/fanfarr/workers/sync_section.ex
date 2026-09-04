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
      collections = collections(config, section, items)

      # Before the upsert, or the renamed item is already in as a second row
      # and there is nothing left to re-key.
      adopt_renames(section, items)

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
            studio: item.studio,
            collections: Map.get(collections, item.rating_key, item.collections),
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

  # Collection membership, from the library's own collections rather than from
  # the per-item Collection tags.
  #
  # The tags are not the whole truth. A library shows both the collections the
  # operator built by hand and the ones its agent assembled from TMDB -- the
  # "Star Wars Collection", "Dune Collection" sort -- and only the hand-made
  # ones reliably come back as tags on the item. Asking the library what
  # collections it has, and what is in each, gets both.
  #
  # One request per collection, and collections number in the tens where items
  # number in the thousands. A library with none costs exactly one request.
  # Every failure degrades to the listing's tags rather than failing the sync:
  # a missing collection is a filter with fewer options, not a broken mirror.
  defp collections(config, section, items) do
    case Fanfarr.Plex.Client.impl().collections(config, section.plex_key) do
      {:ok, []} ->
        %{}

      {:ok, collections} ->
        merge_tags(memberships(config, collections), items)

      {:error, reason} ->
        Logger.warning(
          "[fanfarr] could not read collections for section #{section.title} " <>
            "(#{inspect(reason)}); falling back to the tags on the listing"
        )

        %{}
    end
  end

  defp memberships(config, collections) do
    collections
    |> Task.async_stream(
      fn collection ->
        case Fanfarr.Plex.Client.impl().collection_items(config, collection.rating_key) do
          {:ok, rating_keys} -> {collection.title, rating_keys}
          {:error, _reason} -> {collection.title, []}
        end
      end,
      max_concurrency: @origin_concurrency,
      timeout: @origin_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {title, rating_keys}} -> Enum.map(rating_keys, &{&1, title})
      {:exit, _reason} -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The listing's own tags still count. They should be a subset of what the
  # collections endpoint reports, but a tag we can see and a membership we
  # cannot is a collection the operator would notice missing.
  defp merge_tags(memberships, items) do
    Enum.reduce(items, memberships, fn item, acc ->
      case item.collections do
        [] ->
          acc

        tags ->
          Map.update(acc, item.rating_key, tags, &Enum.uniq(&1 ++ tags))
      end
    end)
  end

  # --- renames and removals ---------------------------------------------------
  #
  # Rename a folder and Plex does not update the item: it drops the old
  # ratingKey and issues a new one for the new name. A purely additive sync
  # therefore left the library showing both, which is what "The Dark Knight"
  # appearing twice was -- one row per name the folder has ever had.
  #
  # The obvious fix, deleting what the listing no longer contains, is right for
  # a removal and wrong for a rename: the row Plex "dropped" is the one holding
  # everything Plex does not know about, the operator's chosen theme and the
  # whole application log. Deleting it and creating its replacement fresh throws
  # that away and quietly re-does work someone already did by hand.
  #
  # So a departure and an arrival that are the same title get paired first, and
  # the surviving row is re-keyed rather than replaced. Only what is left after
  # that -- an item genuinely gone from Plex -- is deleted.

  # Pair each departing item with the arriving one carrying the same external
  # id, and move the existing row onto the new ratingKey.
  #
  # Matching is on imdb/tmdb/tvdb rather than on title, because a title is not
  # an identity: a library can hold two cuts of one film, and "The Dark Knight"
  # matching "The Dark Knight" would be right for a rename and wrong for those.
  # An id is what Radarr and Plex themselves key on.
  defp adopt_renames(section, items) do
    stored = Library.media_items_in_section!(section.id)

    listed_keys = MapSet.new(items, & &1.rating_key)
    stored_keys = MapSet.new(stored, & &1.plex_rating_key)

    departing = Enum.reject(stored, &MapSet.member?(listed_keys, &1.plex_rating_key))
    arriving = Enum.reject(items, &MapSet.member?(stored_keys, &1.rating_key))

    departing
    |> Enum.map(&{&1, sole_match(&1, arriving)})
    |> Enum.reject(fn {_item, match} -> is_nil(match) end)
    |> unambiguous()
    |> Enum.each(fn {item, match} ->
      Logger.info(
        "[fanfarr] #{item.title} came back under a new ratingKey " <>
          "(#{item.plex_rating_key} -> #{match.rating_key}), most likely a rename; " <>
          "keeping its theme and history"
      )

      Library.adopt_plex_rating_key!(item, %{plex_rating_key: match.rating_key})
    end)
  end

  # An arriving item sharing an id with this one, and only if there is exactly
  # one. Two candidates mean the guess is not safe to make, and guessing wrong
  # would attach one item's theme to another.
  defp sole_match(item, arriving) do
    ids = external_ids(item)

    case Enum.filter(arriving, &(&1.kind == item.kind and shares_id?(external_ids(&1), ids))) do
      [match] -> match
      _ -> nil
    end
  end

  # ...and the pairing has to be one-to-one in the other direction too. Two
  # departing items both pointing at one arrival is the same unsafe guess seen
  # from the other side.
  defp unambiguous(pairs) do
    counts = Enum.frequencies_by(pairs, fn {_item, match} -> match.rating_key end)

    Enum.filter(pairs, fn {_item, match} -> counts[match.rating_key] == 1 end)
  end

  defp external_ids(item) do
    for db <- [:imdb_id, :tmdb_id, :tvdb_id],
        id = presence(Map.get(item, db)),
        into: %{},
        do: {db, id}
  end

  defp shares_id?(left, right) do
    Enum.any?(right, fn {db, id} -> Map.get(left, db) == id end)
  end

  # Whatever is still unaccounted for once renames are paired off: items Plex
  # genuinely no longer has. Deleting takes the application log rows with them
  # by cascade, so this is the one path that loses history -- which is why the
  # rename case is handled first and why an empty listing is not believed.
  defp prune(section, items) do
    listed = MapSet.new(items, & &1.rating_key)

    # An empty listing is not evidence that a library is empty. Plex returns
    # one while a scan is in progress, and a section whose storage is offline
    # reports no items rather than an error. Believing it would delete the
    # entire mirror, and with it every theme Fanfarr has recorded applying.
    if MapSet.size(listed) == 0 do
      Logger.warning(
        "[fanfarr] Plex listed no items in section #{section.title}; " <>
          "nothing removed, since an empty listing is more likely a scan in progress"
      )
    else
      section.id
      |> Library.media_items_in_section!()
      |> Enum.reject(&MapSet.member?(listed, &1.plex_rating_key))
      |> Enum.each(fn item ->
        Logger.info(
          "[fanfarr] Plex no longer lists #{item.title} (ratingKey #{item.plex_rating_key}); " <>
            "removing it and its theme history"
        )

        Library.delete_media_item!(item)
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
