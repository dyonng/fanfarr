defmodule Fanfarr.Library.MediaItem.ThemeDuration do
  @moduledoc """
  How long the theme Fanfarr wrote for an item plays, in milliseconds, or nil
  when nothing is known.

  The Length column on the library, derived from the same reading of the log
  that `ThemeSize` uses -- `Fanfarr.Themes.ApplicationFacts`, where the rule
  for which row wins is argued.

  nil rather than 0 for "unknown": a theme with no recorded length is not a
  theme that plays for no time, and the column shows a dash for it. Rows
  applied before the column existed are nil until something measures them,
  which is why the value is nullable rather than defaulted.
  """
  use Ash.Resource.Calculation

  alias Fanfarr.Themes.ApplicationFacts

  @impl true
  def load(_query, _opts, _context), do: []

  @impl true
  def calculate([], _opts, _context), do: []

  def calculate(records, _opts, _context) do
    facts = ApplicationFacts.latest(Enum.map(records, & &1.id))

    Enum.map(records, fn record ->
      facts |> Map.get(record.id, %{}) |> Map.get(:duration_ms)
    end)
  end
end
