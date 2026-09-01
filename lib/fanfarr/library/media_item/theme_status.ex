defmodule Fanfarr.Library.MediaItem.ThemeStatus do
  @moduledoc """
  Derives an item's theme status from the facts already recorded about it.

  The brief asks us to distinguish five states that Themerr conflated, because
  each implies different available actions. They are conclusions, not stored
  data: what Plex reports, whether a theme.mp3 exists on disk, and what our
  append-only application log says. A stored status column would be a fourth
  fact that eventually disagrees with the other three.

  ## Why this queries the log itself

  The obvious shape is a `first` aggregate over `theme_applications`, but
  AshSqlite does not support resource-level aggregates -- `can?({:aggregate,
  _})` returns false, so the resource will not compile with one. Rather than
  denormalise the log's latest state onto the item, where it could drift, the
  calculation fetches it: one query for the whole batch of records being
  loaded, not one per record.
  """
  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def load(_query, _opts, _context) do
    [:local_theme_present, :plex_theme_url, :plex_theme_provider]
  end

  @impl true
  def calculate([], _opts, _context), do: []

  def calculate(records, _opts, _context) do
    latest = latest_applications(Enum.map(records, & &1.id))

    Enum.map(records, fn record ->
      status(record, Map.get(latest, record.id))
    end)
  end

  # One query for every record in the batch. Dry runs are excluded throughout:
  # a preview must never change what the dashboard reports about an item.
  defp latest_applications(item_ids) do
    Fanfarr.Themes.ThemeApplication
    |> Ash.Query.filter(media_item_id in ^item_ids and dry_run == false)
    |> Ash.Query.select([:media_item_id, :status, :inserted_at])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
    # Ascending sort means a later row overwrites an earlier one, leaving the
    # most recent application per item.
    |> Map.new(&{&1.media_item_id, &1.status})
  end

  # Order matters. An item can satisfy several conditions at once -- a failed
  # attempt against something that already has a Plex-supplied theme -- and the
  # status should report whichever the operator most needs to act on.
  defp status(item, last_status) do
    cond do
      # A failure outranks everything: it is the only state asking the operator
      # to do something, and it is otherwise invisible.
      last_status == :failed ->
        :failed

      # We put this here and we know it, because the log says so. Reported even
      # if Plex has not picked it up yet, which is itself a drift signal.
      last_status == :succeeded ->
        :fanfarr_applied

      # A theme.mp3 beside the media. Durable, survives anything Plex does to
      # its API, and not ours to claim credit for.
      item.local_theme_present or item.plex_theme_provider == "local" ->
        :local_file

      is_binary(item.plex_theme_url) and item.plex_theme_url != "" ->
        :plex_supplied

      true ->
        :missing
    end
  end
end
