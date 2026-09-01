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

  alias Fanfarr.Library

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"section_id" => section_id}}) do
    section = Library.get_section!(section_id)

    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, items} <- Fanfarr.Plex.Client.impl().items(config, section.plex_key) do
      origins = origins(config, items)

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
            plex_path: item.path,
            imdb_id: item.imdb_id,
            tmdb_id: item.tmdb_id,
            tvdb_id: item.tvdb_id,
            plex_thumb_key: item.thumb,
            plex_theme_url: item.theme,
            plex_theme_origin: origin,
            plex_theme_agent: agent,
            added_at: item.added_at
          })
        end)
      end)

      Phoenix.PubSub.broadcast(Fanfarr.PubSub, "library", {:section_synced, section.id})
      :ok
    else
      {:error, :plex_not_configured} -> {:cancel, :plex_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  # Concurrency is deliberately modest: this is someone's media server, often
  # the same box that is transcoding, and a sync is background work.
  @origin_concurrency 8
  @origin_timeout 15_000

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
