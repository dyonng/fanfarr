defmodule Fanfarr.Workers.LookupTheme do
  @moduledoc """
  One ThemerrDB lookup for one item: IMDB first, TMDB as fallback, first hit
  wins -- the strategy the reference implementation proved out. Both hits and
  404s are recorded, so an absent title is never re-requested inside its TTL.
  """
  use Oban.Worker,
    queue: :themerrdb,
    max_attempts: 5,
    unique: [period: 3600, keys: [:media_item_id], states: [:available, :scheduled, :executing]]

  @external_id ~r/^[A-Za-z0-9_\-]{1,64}$/

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id}}) do
    item = Fanfarr.Library.get_media_item!(item_id)
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    result =
      [imdb: item.imdb_id, themoviedb: item.tmdb_id]
      |> Enum.filter(fn {_db, id} -> is_binary(id) and Regex.match?(@external_id, id) end)
      |> Enum.reduce_while(:ok, fn {db, id}, _acc ->
        case lookup(item_type, db, id) do
          {:hit, _entry} -> {:halt, :ok}
          :miss -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    Phoenix.PubSub.broadcast(Fanfarr.PubSub, "item:#{item.id}", {:item_updated, item.id})
    result
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Themerr-plex used plain exponential backoff for upstream flakiness;
    # same shape here, in seconds.
    trunc(:math.pow(2, attempt) * 15)
  end

  defp lookup(item_type, database, external_id) do
    url = "#{Fanfarr.Themes.ThemerrDB.base_url()}/#{item_type}/#{database}/#{external_id}.json"

    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, entry} =
          Fanfarr.Themes.record_themerr_lookup(%{
            item_type: item_type,
            database: database,
            external_id: external_id,
            found: true,
            youtube_theme_url: body["youtube_theme_url"],
            youtube_theme_added: body["youtube_theme_added"],
            youtube_theme_edited: body["youtube_theme_edited"]
          })

        {:hit, entry}

      {:ok, %{status: 404}} ->
        # Misses are cached too; most of a library is not in ThemerrDB.
        {:ok, _} =
          Fanfarr.Themes.record_themerr_lookup(%{
            item_type: item_type,
            database: database,
            external_id: external_id,
            found: false
          })

        :miss

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
