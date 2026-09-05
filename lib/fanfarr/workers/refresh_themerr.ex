defmodule Fanfarr.Workers.RefreshThemerr do
  @moduledoc """
  Fans out one ThemerrDB lookup per item that needs one.

  ThemerrDB has no bulk endpoint, so a cold pass over this library is ~2,550
  individual requests. The per-item jobs run on the :themerrdb queue, whose
  low concurrency is a courtesy to a community-run service -- parallel enough
  to finish in reasonable time, never a hammering.

  An item needs a lookup when it has no cached entry, or its entry is stale.
  Freshness beyond the TTL is judged by youtube_theme_edited on re-fetch, not
  here.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # See Fanfarr.Scheduling: the next run is counted from here, so a pass
    # triggered by a library sync pushes the interval out the same as a
    # scheduled one.
    Fanfarr.Scheduling.record_run(:themerrdb_refresh)

    known =
      Fanfarr.Themes.list_themerr_entries!()
      |> MapSet.new(&{&1.item_type, &1.database, &1.external_id})

    Fanfarr.Library.list_media_items!()
    |> Enum.filter(&needs_lookup?(&1, known))
    |> Enum.each(fn item ->
      %{media_item_id: item.id}
      |> Fanfarr.Workers.LookupTheme.new()
      |> Oban.insert!()
    end)

    :ok
  end

  defp needs_lookup?(item, known) do
    lookups(item) != [] and not Enum.any?(lookups(item), &MapSet.member?(known, &1))
  end

  defp lookups(item) do
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    for {db, id} <- [imdb: item.imdb_id, themoviedb: item.tmdb_id],
        id not in [nil, ""],
        do: {item_type, db, id}
  end
end
