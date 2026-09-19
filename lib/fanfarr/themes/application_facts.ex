defmodule Fanfarr.Themes.ApplicationFacts do
  @moduledoc """
  What the append-only application log says about an item's theme *now*: how
  many bytes it occupies and how long it plays.

  Derived once, here, because two calculations read it (`ThemeSize` for the
  library's Size column and the dashboard total, `ThemeDuration` for its Length
  column) and the rule for which row wins is the whole difficulty. Two copies
  of it would eventually disagree about the same file.

  ## Why the newest row is not always the answer

  Rows are append-only: a retry is another row, nothing is updated, and a
  removal is its own row rather than an edit of the apply's. So a naive
  `SUM(bytes)` over the log double-bills every retry, and the newest row alone
  is wrong in one direction:

    * a `:succeeded` row is a file we placed, and its `bytes` and `duration_ms`
      are that file's.

    * a later `:failed` row leaves the previous file exactly where it was.
      `Fanfarr.Themes.Writer` stages to a temp name and renames, so a failed
      apply never half-replaces a theme that is already there, and the last
      successful numbers have to carry forward. Same for `:skipped`, which is
      the idempotency path -- it means the intended theme was already applied.

    * a `:removed` row means it is gone: no bytes and no length.

    * a `:succeeded` row with no recorded number (applied before the columns
      existed, or a path that could not measure it) leaves the previous value
      standing rather than blanking a fact we already had.

  One query for the whole batch being loaded, not one per record: AshSqlite has
  no resource-level aggregates, and denormalising this onto the item would be
  another fact that eventually disagrees with the log.
  """

  require Ash.Query

  @type facts :: %{bytes: non_neg_integer(), duration_ms: non_neg_integer() | nil}

  @doc """
  The current facts for each of `item_ids`, as `%{item_id => facts}`.

  Ids with no rows at all are absent rather than zeroed, so a caller can tell
  "nothing was ever applied" from "the log says the file is gone".
  """
  @spec latest([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => facts()}
  def latest([]), do: %{}

  def latest(item_ids) do
    Fanfarr.Themes.ThemeApplication
    |> Ash.Query.filter(media_item_id in ^item_ids)
    |> Ash.Query.select([:media_item_id, :status, :bytes, :duration_ms, :inserted_at])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
    # Ascending order, so a later row overwrites an earlier one.
    |> Enum.reduce(%{}, fn row, acc ->
      Map.update(acc, row.media_item_id, from_row(row), &after_row(&1, row))
    end)
  end

  defp from_row(row), do: after_row(%{bytes: 0, duration_ms: nil}, row)

  defp after_row(facts, row) do
    %{
      bytes: bytes_after(facts.bytes, row),
      duration_ms: duration_after(facts.duration_ms, row)
    }
  end

  defp bytes_after(_previous, %{status: :succeeded, bytes: bytes}) when is_integer(bytes),
    do: bytes

  defp bytes_after(_previous, %{status: :removed}), do: 0
  defp bytes_after(previous, _row), do: previous

  defp duration_after(_previous, %{status: :succeeded, duration_ms: ms}) when is_integer(ms),
    do: ms

  defp duration_after(_previous, %{status: :removed}), do: nil
  defp duration_after(previous, _row), do: previous
end
