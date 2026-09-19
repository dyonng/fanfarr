defmodule Fanfarr.Library.MediaItem.ThemeSize do
  @moduledoc """
  How many bytes the theme Fanfarr wrote for an item occupies, or 0.

  The number the library table lists per row and the dashboard totals. Derived
  from `Fanfarr.Themes.ApplicationFacts`, which reads the append-only log and
  argues the rule for which row wins -- why this is not `SUM(bytes)`, why a
  failed or skipped apply carries the last successful size forward, and why a
  removal is nothing.

  0 rather than nil for "we wrote nothing": this feeds a total, and the
  dashboard's arithmetic is simpler for a number. The Length column next to it
  makes the opposite choice, because an unknown length is not a length of zero.
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
      case Map.get(facts, record.id) do
        nil -> 0
        %{bytes: bytes} -> bytes
      end
    end)
  end
end
