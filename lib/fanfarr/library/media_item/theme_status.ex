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
    [:local_theme_present, :plex_theme_url, :plex_theme_origin]
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
      item.local_theme_present ->
        :local_file

      # Plex is serving a theme it picked up from disk. Not ours to claim
      # credit for either, but it is a local file and not stock Plex audio.
      item.plex_theme_origin == :local ->
        :local_file

      # Plex's own agent put this here. Verified against a live server: the
      # theme's ratingKey is metadata://themes/<agent-id>_<sha>. This is the
      # state worth surfacing -- the title looks finished but is running stock
      # Plex audio, and is a candidate for replacement.
      item.plex_theme_origin == :plex_agent ->
        :plex_supplied

      # A theme is present but not one we can attribute -- an upload from
      # before Fanfarr, or a scheme we do not recognise yet.
      is_binary(item.plex_theme_url) and item.plex_theme_url != "" ->
        :plex_supplied

      true ->
        :missing
    end
  end
end
