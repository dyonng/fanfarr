defmodule Fanfarr.Overview do
  @moduledoc """
  Everything the dashboard at `/` reports, gathered in one pass.

  ## Why a module and not a LiveView

  The numbers here are the same ones the library, Activity and System pages
  derive for themselves. Recomputing them inline in a fourth place is how four
  pages end up disagreeing about how many titles are themed, so the definition
  lives here once and the LiveView only renders it.

  ## What "themed" means, and what it deliberately does not

  A title counts as themed when something is playing for it: Fanfarr wrote the
  file, a local theme.mp3 is there, or Plex's own agent supplies one. That last
  case is a judgement call worth stating -- a Plex-supplied theme is stock
  audio and the whole reason this project exists, so it is *not* progress in
  the sense the operator cares about. But calling it "missing" would be a lie
  the library page does not tell, and a dashboard that disagrees with the page
  it links to is worse than one that simplifies. So it counts as covered, and
  it gets its own number alongside, which is where the replace-these work is.

  ## Cost

  Three queries plus the batched `theme_status` calculation, for the whole
  library: sections, items, and one ThemerrDB lookup keyed on the external ids
  of the items that are missing a theme. A few thousand rows in a homelab, and
  the page is a page load rather than a poll.
  """

  require Ash.Query

  alias Fanfarr.Library

  @themed ~w(fanfarr_applied local_file plex_supplied)a

  @type section_coverage :: %{
          id: String.t(),
          title: String.t(),
          kind: :show | :movie,
          total: non_neg_integer(),
          themed: non_neg_integer(),
          missing: non_neg_integer(),
          failed: non_neg_integer(),
          percent: non_neg_integer()
        }

  @doc """
  The whole dashboard, as one map.

  `ready` is the number worth acting on right now: titles with no theme that
  ThemerrDB has an answer for. It is the difference between "130 missing" --
  which is not a task, because most of them have no source -- and "47 you can
  fix with one click", which is.
  """
  def load do
    sections = Library.list_sections!() |> Map.new(&{&1.id, &1})
    items = Library.list_media_items!(load: [:theme_status])

    by_status = Enum.frequencies_by(items, & &1.theme_status)
    missing = Enum.filter(items, &(&1.theme_status == :missing))

    %{
      sections: coverage(items, sections),
      totals: totals(items, by_status),
      plex_supplied: Map.get(by_status, :plex_supplied, 0),
      failed: Map.get(by_status, :failed, 0),
      ready: ready(missing),
      recent: recently_added(items),
      queue: Fanfarr.Jobs.summary(),
      eta_seconds: Fanfarr.Jobs.eta_seconds(),
      schedule: schedule(),
      health: health()
    }
  end

  defp totals(items, by_status) do
    total = length(items)
    themed = Enum.reduce(@themed, 0, &(&2 + Map.get(by_status, &1, 0)))

    %{
      total: total,
      themed: themed,
      missing: Map.get(by_status, :missing, 0),
      percent: percent(themed, total)
    }
  end

  # Per section, because "396 of 742" is one number and "TV is behind, films
  # are done" is the actual shape of the work. Sections with nothing in them
  # are dropped rather than shown at 0%: an unsynced or disabled library is
  # not a coverage problem and reads as one.
  defp coverage(items, sections) do
    items
    |> Enum.group_by(& &1.section_id)
    |> Enum.map(fn {section_id, group} ->
      counts = Enum.frequencies_by(group, & &1.theme_status)
      themed = Enum.reduce(@themed, 0, &(&2 + Map.get(counts, &1, 0)))
      section = Map.get(sections, section_id)

      %{
        id: section_id,
        title: (section && section.title) || "Unknown library",
        kind: section && section.kind,
        total: length(group),
        themed: themed,
        missing: Map.get(counts, :missing, 0),
        failed: Map.get(counts, :failed, 0),
        percent: percent(themed, length(group))
      }
    end)
    |> Enum.sort_by(&{&1.percent, -&1.total})
  end

  # Items with no theme that ThemerrDB can answer for. Matched in memory
  # against one query rather than asked per item: a cold library is a couple
  # of thousand titles, and that would be a couple of thousand round trips to
  # render a number.
  defp ready(missing) do
    ids =
      missing
      |> Enum.flat_map(&[&1.imdb_id, &1.tmdb_id])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    if ids == [] do
      0
    else
      answered =
        Fanfarr.Themes.ThemerrEntry
        |> Ash.Query.for_read(:by_external_ids, %{external_ids: ids})
        |> Ash.Query.filter(not is_nil(youtube_theme_url) and youtube_theme_url != "")
        |> Ash.Query.select([:external_id])
        |> Ash.read!(authorize?: false)
        |> MapSet.new(& &1.external_id)

      Enum.count(missing, fn item ->
        MapSet.member?(answered, item.imdb_id) or MapSet.member?(answered, item.tmdb_id)
      end)
    end
  end

  @doc """
  The ids of every item a bulk apply from here would act on.

  Recomputed rather than carried in the socket: the button is on a page that
  can sit open for hours, and applying to a list assembled before the last
  sync would work on titles that have since been themed or removed.
  """
  def ready_ids do
    Library.list_media_items!(load: [:theme_status])
    |> Enum.filter(&(&1.theme_status == :missing))
    |> then(fn missing ->
      ids =
        missing
        |> Enum.flat_map(&[&1.imdb_id, &1.tmdb_id])
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()

      if ids == [] do
        []
      else
        answered =
          Fanfarr.Themes.ThemerrEntry
          |> Ash.Query.for_read(:by_external_ids, %{external_ids: ids})
          |> Ash.Query.filter(not is_nil(youtube_theme_url) and youtube_theme_url != "")
          |> Ash.Query.select([:external_id])
          |> Ash.read!(authorize?: false)
          |> MapSet.new(& &1.external_id)

        missing
        |> Enum.filter(fn item ->
          MapSet.member?(answered, item.imdb_id) or MapSet.member?(answered, item.tmdb_id)
        end)
        |> Enum.map(& &1.id)
      end
    end)
  end

  # What Plex has just picked up. A new season folder or a film that finished
  # importing is exactly the thing that quietly has no theme, and until now the
  # only way to notice was to sort the library by nothing in particular.
  #
  # Sorted on `added_at`, which is Plex's own timestamp rather than ours -- a
  # title we synced today may have been in the library for years, and dating it
  # by our first sight of it would put the whole library on this list the first
  # time it runs. Items Plex reported no date for sort last rather than being
  # dropped: unknown is not new, but it is still real.
  defp recently_added(items) do
    items
    |> Enum.sort_by(& &1.added_at, {:desc, Fanfarr.Overview.DateTimeOrNil})
    |> Enum.take(8)
  end

  defp schedule do
    Enum.map(Fanfarr.Scheduling.tasks(), fn {key, task} ->
      %{
        key: key,
        label: task.label,
        last_run_at: Fanfarr.Scheduling.last_run_at(key),
        next_run_at: Fanfarr.Scheduling.next_run_at(key)
      }
    end)
  end

  # Only what is wrong. A dashboard listing eight green checks buries the one
  # red one, and System already shows them all.
  defp health do
    case Fanfarr.Health.Monitor.latest() do
      %{results: results} ->
        %{
          worst: Fanfarr.Health.worst(results),
          problems: Enum.filter(results, &(&1.level in [:warning, :error]))
        }

      _ ->
        %{worst: nil, problems: []}
    end
  end

  defp percent(_themed, 0), do: 0
  defp percent(themed, total), do: round(themed / total * 100)

  @doc "Whether there is a library at all yet, which decides what the page says."
  def empty?(%{totals: %{total: 0}}), do: true
  def empty?(_), do: false
end

defmodule Fanfarr.Overview.DateTimeOrNil do
  @moduledoc """
  Sort order for a `DateTime` field that is allowed to be nil.

  `Enum.sort_by/3` with `{:desc, DateTime}` raises on a nil, and Plex does not
  report `addedAt` for everything. nil sorts as the smallest value, so with
  `:desc` those land at the end -- unknown is not new, but it is still real and
  dropping the row would be a quieter lie than showing it last.
  """
  def compare(nil, nil), do: :eq
  def compare(nil, _other), do: :lt
  def compare(_other, nil), do: :gt
  def compare(a, b), do: DateTime.compare(a, b)
end
