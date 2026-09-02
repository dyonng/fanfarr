defmodule Fanfarr.Themes.Choice do
  @moduledoc """
  What Fanfarr would apply to an item, and where it would come from.

  One module because two callers need the same answer and must not drift: the
  worker, which needs the URL, and the library table, which needs to say ahead
  of time whether pressing Apply will do anything. A table that disagreed with
  the worker about which items are ready would be worse than no column at all.

  ## Precedence

  A URL passed with the job outranks everything -- it was chosen in the UI a
  moment ago. Then the operator's stored pick, which was made looking at this
  specific title. Then ThemerrDB.

  ## The cold cache

  ThemerrDB is read from our own cache, never fetched here: this runs inside a
  worker that has already decided what it is doing, and inside a page render.
  So an item nobody has looked up yet has no suggestion *as far as the apply
  is concerned*, and reports `:unknown` rather than `:none` -- the difference
  between "ThemerrDB has nothing for this" and "we have not asked", which is
  the difference between a title that cannot be helped and one that only needs
  a lookup queued first.
  """
  alias Fanfarr.Themes

  @type source :: :pick | :themerrdb | :none | :unknown

  @doc """
  The URL to apply and where it came from.
  """
  @spec url(map(), map()) :: {:ok, String.t(), atom()} | {:error, :no_themerrdb_entry}
  def url(item, args \\ %{})

  def url(_item, %{"theme_url" => url} = args) when is_binary(url) and url != "" do
    {:ok, url, source_atom(args["source"], :youtube)}
  end

  def url(%{manual_theme_url: url}, _args) when is_binary(url) and url != "" do
    {:ok, url, :youtube}
  end

  def url(item, _args) do
    case entry(item, entries_for([item])) do
      %{found: true, youtube_theme_url: url} when is_binary(url) and url != "" ->
        {:ok, url, :themerrdb}

      _ ->
        {:error, :no_themerrdb_entry}
    end
  end

  @doc """
  Where each item's theme would come from, keyed by item id.

  One query for the whole page rather than one per row.
  """
  @spec sources([map()]) :: %{optional(String.t()) => source()}
  def sources([]), do: %{}

  def sources(items) do
    entries = entries_for(items)
    Map.new(items, &{&1.id, source(&1, entries)})
  end

  @doc "Where one item's theme would come from, given entries already loaded."
  @spec source(map(), [map()]) :: source()
  def source(%{manual_theme_url: url}, _entries) when is_binary(url) and url != "", do: :pick

  def source(item, entries) do
    case entry(item, entries) do
      %{found: true, youtube_theme_url: url} when is_binary(url) and url != "" -> :themerrdb
      nil -> :unknown
      _ -> :none
    end
  end

  # ThemerrDB is keyed by external id, so the whole page is fetched by the ids
  # it mentions and matched up in memory. Ash cannot express "this tuple of
  # three columns is in that set" here, and a query per row would be a hundred
  # queries to render a table.
  defp entries_for(items) do
    ids =
      items
      |> Enum.flat_map(&[&1.imdb_id, &1.tmdb_id])
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    if ids == [], do: [], else: Themes.themerr_entries_by_external_ids!(ids)
  end

  defp entry(item, entries) do
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    Enum.find_value([imdb: item.imdb_id, themoviedb: item.tmdb_id], fn {database, id} ->
      if is_binary(id) and id != "" do
        Enum.find(
          entries,
          &(&1.item_type == item_type and &1.database == database and &1.external_id == id)
        )
      end
    end)
  end

  defp source_atom("themerrdb", _), do: :themerrdb
  defp source_atom("youtube", _), do: :youtube
  defp source_atom(_, default), do: default
end
