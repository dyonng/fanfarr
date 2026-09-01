defmodule Fanfarr.Workers.SyncSection do
  @moduledoc """
  Mirrors every item in one Plex section into the library.

  Writes are chunked so the sync yields the SQLite write lock between batches
  rather than holding it for the whole section -- the dashboard stays readable
  while 750 shows sync. The Plex reads happen entirely before any write, per
  the rule that no transaction spans HTTP.
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
      items
      |> Enum.chunk_every(100)
      |> Enum.each(fn chunk ->
        Enum.each(chunk, fn item ->
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
end
