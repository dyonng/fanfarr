defmodule Fanfarr.ScheduleTest do
  @moduledoc """
  The crontab, which is the difference between an appliance and a tool.

  It used to carry one entry per recurring job. It now carries a single
  heartbeat, because the intervals became a setting and Oban reads its crontab
  once at boot -- so these check the heartbeat is wired up and that the tasks
  it is responsible for are reachable through it.
  """
  use ExUnit.Case, async: true

  defp crontab do
    :fanfarr
    |> Application.get_env(Oban)
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
      _ -> nil
    end)
  end

  test "the heartbeat that starts everything else is scheduled" do
    workers = Enum.map(crontab(), fn {_expression, worker} -> worker end)

    assert Fanfarr.Workers.Scheduler in workers
  end

  test "the heartbeat is the only thing on the crontab" do
    # Anything added here runs on a fixed schedule the operator cannot see or
    # change from Settings, which is the trap this design exists to avoid.
    # New recurring work belongs in Fanfarr.Scheduling instead.
    assert length(crontab()) == 1
  end

  test "the heartbeat runs often enough for the granularity Settings promises" do
    # Settings tells the operator an interval is accurate to about five
    # minutes. That is only true while this is what the crontab says.
    assert [{"*/5 * * * *", Fanfarr.Workers.Scheduler}] = crontab()
  end

  test "the library sync and the ThemerrDB refresh both still run unattended" do
    # The point of the whole mechanism: nothing in this app ran on its own
    # until it existed.
    workers = Enum.map(Fanfarr.Scheduling.tasks(), fn {_key, task} -> task.worker end)

    assert Fanfarr.Workers.SyncLibrary in workers
    assert Fanfarr.Workers.RefreshThemerr in workers
  end

  test "every task the scheduler knows about has a real worker behind it" do
    for {key, task} <- Fanfarr.Scheduling.tasks() do
      Code.ensure_loaded!(task.worker)

      assert function_exported?(task.worker, :perform, 1),
             "#{inspect(key)} points at #{inspect(task.worker)}, which is not an Oban worker"
    end
  end

  test "every expression parses" do
    # A malformed expression takes Oban's supervision tree down at boot, which
    # is a bad way to find out about a typo.
    for {expression, worker} <- crontab() do
      assert %Oban.Cron.Expression{} = Oban.Cron.Expression.parse!(expression),
             "#{inspect(worker)} has an unparseable schedule: #{expression}"
    end
  end
end
