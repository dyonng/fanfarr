defmodule Fanfarr.Workers.SyncLibrary do
  @moduledoc """
  Mirrors Plex's section list, then fans out one job per enabled section.

  Fan-out rather than one long job: sections sync in parallel across the queue,
  one section failing retries alone, and the Activity view shows per-section
  progress instead of a single opaque task. `unique` stops a manual "Sync Now"
  from stacking on a scheduled run already in flight.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  alias Fanfarr.Library
  alias Fanfarr.Plex.Client

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Before the work, and whatever the outcome: this is what the scheduler
    # counts the next run from, and a sync started by hand has to reset that
    # clock the same as a scheduled one does. See Fanfarr.Scheduling.
    Fanfarr.Scheduling.record_run(:sync_library)

    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, sections} <- Client.impl().sections(config) do
      Enum.each(sections, fn s ->
        Library.sync_section_from_plex!(%{
          plex_key: s.key,
          title: s.title,
          kind: s.kind,
          plex_locations: s.locations
        })
      end)

      Library.list_sections!()
      |> Enum.filter(& &1.enabled)
      |> Enum.each(fn section ->
        %{section_id: section.id}
        |> Fanfarr.Workers.SyncSection.new()
        |> Oban.insert!()
      end)

      # A sync is the only thing that introduces new titles, so it is the only
      # moment ThemerrDB has something new to be asked about. Delayed rather
      # than immediate: the sections are still syncing, and a lookup pass that
      # runs before they finish would miss exactly the items that prompted it.
      # RefreshThemerr's own uniqueness collapses this against the nightly run.
      %{}
      |> Fanfarr.Workers.RefreshThemerr.new(schedule_in: 180)
      |> Oban.insert!()

      :ok
    else
      # Not configured is not a failure to retry -- there is nothing to sync
      # until the operator supplies a server. The dashboard reports the state.
      {:error, :plex_not_configured} -> {:cancel, :plex_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end
end
