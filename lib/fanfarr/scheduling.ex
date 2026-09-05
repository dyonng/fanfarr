defmodule Fanfarr.Scheduling do
  @moduledoc """
  How often the recurring jobs run, and when each is next due.

  ## Why this is not a crontab

  Oban's Cron plugin reads its crontab once, at boot, and open-source Oban has
  no API to change it after that -- dynamic cron is a Pro feature. So a
  schedule the operator can edit from Settings cannot *be* a crontab entry.
  Instead one crontab entry runs `Fanfarr.Workers.Scheduler` every five
  minutes, and this module answers the only question that heartbeat asks: is
  this task due yet?

  Five minutes is therefore the granularity of every interval here. An hourly
  task fires within five minutes of its hour, which is well inside what any of
  this is sensitive to.

  ## "Due" is measured from the last run, not from a fixed clock

  A task records its own start time, and the next run is that plus the
  interval. The alternative -- firing on wall-clock boundaries -- means
  pressing "Sync library" by hand at 05:58 gets you synced again at 06:00.
  Recording it in the worker rather than in the heartbeat is what makes a
  manual run count: however the job got queued, it resets the clock.

  Setting `0` turns a schedule off. Nothing else changes: the buttons still
  work, and this only stops Fanfarr starting the work on its own.
  """

  require Logger

  @tasks [
    sync_library: %{
      worker: Fanfarr.Workers.SyncLibrary,
      label: "Library sync",
      description: "Ask Plex what changed, then look up anything new.",
      setting: "sync_interval_hours",
      default_hours: 6
    },
    themerrdb_refresh: %{
      worker: Fanfarr.Workers.RefreshThemerr,
      label: "ThemerrDB refresh",
      description:
        "Re-ask ThemerrDB about titles it had nothing for. A library sync also " <>
          "triggers this, so it rarely waits the full interval.",
      setting: "themerrdb_interval_hours",
      default_hours: 24
    }
  ]

  # A day and a half of hours. Past that the setting is indistinguishable from
  # off, and someone has typed a year by accident.
  @max_hours 336

  @type task :: :sync_library | :themerrdb_refresh

  @doc "Every schedulable task, in the order Settings should show them."
  @spec tasks() :: [{task(), map()}]
  def tasks, do: @tasks

  @spec task(task()) :: map()
  def task(key), do: Keyword.fetch!(@tasks, key)

  @doc """
  The interval in hours, or 0 for off.

  Resolved the way every other setting is: dashboard override, then
  environment variable, then the compiled default. Anything unparseable is the
  default rather than an error -- a typo in an env var should not stop the
  appliance scheduling itself.
  """
  @spec interval_hours(task()) :: non_neg_integer()
  def interval_hours(key) do
    %{setting: setting, default_hours: default} = task(key)

    case Fanfarr.Config.get(setting) do
      nil -> default
      value -> parse_hours(value) || default
    end
  end

  @doc """
  Stores an interval, or clears it back to the default when given "".

  Returns `{:error, :invalid}` rather than storing nonsense, so the form can
  say so instead of silently keeping the old value.
  """
  @spec put_interval_hours(task(), String.t()) :: :ok | {:error, :invalid}
  def put_interval_hours(key, value) do
    %{setting: setting} = task(key)

    case String.trim(to_string(value)) do
      "" ->
        Fanfarr.Settings.put_setting!(setting, nil)
        :ok

      trimmed ->
        case parse_hours(trimmed) do
          nil ->
            {:error, :invalid}

          hours ->
            Fanfarr.Settings.put_setting!(setting, Integer.to_string(hours))
            :ok
        end
    end
  end

  @doc "When this task last started, or nil if it never has on this install."
  @spec last_run_at(task()) :: DateTime.t() | nil
  def last_run_at(key) do
    case Fanfarr.Config.get(last_run_setting(key)) do
      nil ->
        nil

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _offset} -> at
          _ -> nil
        end
    end
  end

  @doc """
  Records that a task is running now. Called by the worker itself, at the top
  of `perform/1`, so a manual run counts the same as a scheduled one.

  Recorded when the run *starts* rather than when it finishes: a sync that
  fans out to fifty section jobs has no single moment of completion, and a run
  that cancels because Plex is not configured yet should still push the next
  attempt out rather than being retried every five minutes.
  """
  @spec record_run(task()) :: :ok
  def record_run(key) do
    Fanfarr.Settings.put_setting!(last_run_setting(key), DateTime.to_iso8601(DateTime.utc_now()))
    :ok
  end

  @doc "When this task is next due, or nil when it is off or has never run."
  @spec next_run_at(task()) :: DateTime.t() | nil
  def next_run_at(key) do
    hours = interval_hours(key)

    case {hours, last_run_at(key)} do
      {0, _} -> nil
      {_, nil} -> nil
      {hours, last} -> DateTime.add(last, hours * 3600, :second)
    end
  end

  @doc """
  Whether the heartbeat should queue this task now.

  A task that has never run is due immediately, which is what makes a fresh
  install sync itself shortly after boot rather than sitting idle for six
  hours waiting for a first data point.
  """
  @spec due?(task(), DateTime.t()) :: boolean()
  def due?(key, now) do
    case {interval_hours(key), next_run_at(key)} do
      # Off.
      {0, _} -> false
      # Never run: nothing to count from, so start now.
      {_, nil} -> true
      {_, next} -> DateTime.compare(now, next) != :lt
    end
  end

  @doc """
  Queues a task's worker. Both workers are `unique`, so this collapses against
  a run already queued or in flight rather than stacking a second one.
  """
  @spec enqueue(task()) :: :ok
  def enqueue(key) do
    %{worker: worker, label: label} = task(key)

    case %{} |> worker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("[fanfarr] could not queue #{label}: #{inspect(reason)}")
        :ok
    end
  end

  defp last_run_setting(key), do: "#{key}_last_run_at"

  defp parse_hours(value) do
    case Integer.parse(String.trim(value)) do
      {hours, ""} when hours >= 0 and hours <= @max_hours -> hours
      _ -> nil
    end
  end
end
