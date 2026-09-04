defmodule Fanfarr.Themes.Choice do
  @moduledoc """
  What Fanfarr would apply to an item, and where it would come from.

  ## Precedence

  A URL passed with the job outranks everything -- it was chosen in the UI a
  moment ago. Then the operator's stored pick, which was made looking at this
  specific title. Then ThemerrDB.

  ## The cold cache

  ThemerrDB is read from our own cache, never fetched here: this runs inside a
  worker that has already decided what it is doing. So an item nobody has
  looked up yet has no suggestion *as far as the apply is concerned*, and
  fails with `:no_themerrdb_entry` the same as a title ThemerrDB genuinely has
  nothing for -- the remedy differs (queue a lookup, or pick one by hand) but
  the apply cannot proceed either way.
  """
  alias Fanfarr.Themes

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

  # ThemerrDB is keyed by external id, so entries are fetched by the ids the
  # items mention and matched up in memory. Ash cannot express "this tuple of
  # three columns is in that set" here.
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
