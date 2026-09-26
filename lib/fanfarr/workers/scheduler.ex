defmodule Fanfarr.Workers.Scheduler do
  @moduledoc """
  The heartbeat that queues the recurring jobs when they are due.

  One crontab entry rather than one per task, because the intervals are a
  setting and Oban's crontab is fixed at boot -- see `Fanfarr.Scheduling` for
  why the schedule cannot live in the crontab itself.

  `max_attempts: 1`: there is nothing here worth retrying. If a tick fails,
  the next one is five minutes away and will find the same tasks still due.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Enum.each(Fanfarr.Scheduling.tasks(), fn {key, _task} ->
      if Fanfarr.Scheduling.due?(key, now), do: Fanfarr.Scheduling.enqueue(key)
    end)

    # Not a scheduled task with its own interval: the trim cache is an
    # implementation detail with nothing for an operator to decide about, and
    # a directory listing every five minutes is cheaper than a settings row.
    # It also self-sweeps on write, so this only matters for a cache that was
    # filled and then left alone.
    Fanfarr.Themes.SourceCache.sweep()

    # Same reasoning: how much history the Activity page keeps is a setting,
    # but *when* it is enforced is not something to decide about. Oban's own
    # pruner is by age and cannot express a count, so this is the only thing
    # bounding the job table.
    Fanfarr.Jobs.prune_history!()

    # And the same reasoning again for the database itself. How many snapshots
    # to keep and how far apart they are settings, but the heartbeat is where
    # "is one due" gets asked -- and it only asks: the copy is queued as its own
    # job, because reading the whole database is not work to do inside the tick
    # that exists to enqueue everything else.
    #
    # The database is the whole of this appliance's state -- the settings, the
    # mirror, and the record of every theme written -- and nothing else on disk
    # can reconstruct it.
    case Fanfarr.Workers.Backup.enqueue_if_due() do
      {:error, reason} ->
        Logger.warning(
          "[fanfarr] could not queue a database backup: #{inspect(reason, limit: 3)}"
        )

      _queued_or_not_due ->
        :ok
    end

    :ok
  end
end
