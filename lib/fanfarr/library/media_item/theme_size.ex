defmodule Fanfarr.Library.MediaItem.ThemeSize do
  @moduledoc """
  How many bytes the theme Fanfarr wrote for an item occupies, or 0.

  The number the library table lists per row and the dashboard totals. Derived
  once, here, so a row and the sum of every row cannot disagree about the same
  file.

  ## Why this is not `SUM(bytes)`

  `theme_applications` is append-only, so a re-apply is a second row and a sum
  would count the same title twice. What is on disk is the newest row -- but
  the newest row does not decide it on its own:

    * a `:succeeded` row is a file we placed, and its `bytes` is that file,
      re-statted after any re-encode so it is the size that was written rather
      than the size that was downloaded.

    * a later `:failed` row leaves the previous file exactly where it was.
      `Fanfarr.Themes.Writer` stages to a temp name and renames, so a failed
      apply never half-replaces a theme that is already there, and the last
      successful size has to carry forward.

    * a `:removed` row means it is gone, so the size is 0.

  ## Why this queries the log itself

  The same reason `ThemeStatus` does: AshSqlite has no resource-level
  aggregates, and denormalising the log's latest state onto the item would be
  a fourth fact that eventually disagrees with the other three. One query for
  the whole batch being loaded, not one per record.
  """
  use Ash.Resource.Calculation

  require Ash.Query

  # Nothing off the item itself is needed beyond its id.
  @impl true
  def load(_query, _opts, _context), do: []

  @impl true
  def calculate([], _opts, _context), do: []

  def calculate(records, _opts, _context) do
    sizes = written_bytes(Enum.map(records, & &1.id))

    Enum.map(records, fn record -> Map.get(sizes, record.id, 0) end)
  end

  # One query for every record in the batch. Ascending sort so a later row
  # overwrites an earlier one, which is the same shape `ThemeStatus` reads the
  # log with.
  defp written_bytes(item_ids) do
    Fanfarr.Themes.ThemeApplication
    |> Ash.Query.filter(media_item_id in ^item_ids)
    |> Ash.Query.select([:media_item_id, :status, :bytes, :inserted_at])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(%{}, fn row, acc ->
      Map.update(acc, row.media_item_id, size_after(0, row), &size_after(&1, row))
    end)
  end

  defp size_after(_previous, %{status: :succeeded, bytes: bytes}) when is_integer(bytes),
    do: bytes

  defp size_after(_previous, %{status: :removed}), do: 0
  defp size_after(previous, _row), do: previous
end
