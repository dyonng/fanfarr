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

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Enum.each(Fanfarr.Scheduling.tasks(), fn {key, _task} ->
      if Fanfarr.Scheduling.due?(key, now), do: Fanfarr.Scheduling.enqueue(key)
    end)

    :ok
  end
end
