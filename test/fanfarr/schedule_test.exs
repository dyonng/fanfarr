defmodule Fanfarr.ScheduleTest do
  @moduledoc """
  The crontab, which is the difference between an appliance and a tool.
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

  test "the library syncs and ThemerrDB refreshes on their own" do
    workers = Enum.map(crontab(), fn {_expression, worker} -> worker end)

    assert Fanfarr.Workers.SyncLibrary in workers
    assert Fanfarr.Workers.RefreshThemerr in workers
  end

  test "every expression parses" do
    # A malformed expression takes Oban's supervision tree down at boot, which
    # is a bad way to find out about a typo.
    for {expression, worker} <- crontab() do
      assert %Oban.Cron.Expression{} = Oban.Cron.Expression.parse!(expression),
             "#{inspect(worker)} has an unparseable schedule: #{expression}"
    end
  end

  test "every scheduled worker is a real Oban worker" do
    for {_expression, worker} <- crontab() do
      Code.ensure_loaded!(worker)

      assert function_exported?(worker, :perform, 1),
             "#{inspect(worker)} is scheduled but is not an Oban worker"
    end
  end

  test "the two jobs do not start at the same minute" do
    # Both walk the whole library; overlapping them puts a sync and 2,550
    # lookups on the same queue at once for no reason.
    minutes = Enum.map(crontab(), fn {expression, _} -> expression end)
    assert length(Enum.uniq(minutes)) == length(minutes)
  end
end
