defmodule Fanfarr.SchedulingTest do
  @moduledoc """
  When each recurring task is due, which is the whole of what the heartbeat
  asks and therefore the whole of what can go wrong with it.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Scheduling

  @now ~U[2026-09-05 12:00:00Z]

  describe "intervals" do
    test "a fresh install gets the compiled defaults" do
      assert Scheduling.interval_hours(:sync_library) == 6
      assert Scheduling.interval_hours(:themerrdb_refresh) == 24
    end

    test "a saved interval wins" do
      assert :ok = Scheduling.put_interval_hours(:sync_library, "12")
      assert Scheduling.interval_hours(:sync_library) == 12
    end

    test "clearing it falls back to the default rather than to zero" do
      # Zero means off, and "" means "I did not want to choose" -- collapsing
      # the two would silently disable the sync for anyone who blanks a field.
      assert :ok = Scheduling.put_interval_hours(:sync_library, "12")
      assert :ok = Scheduling.put_interval_hours(:sync_library, "")

      assert Scheduling.interval_hours(:sync_library) == 6
    end

    test "nonsense is refused rather than stored" do
      assert :ok = Scheduling.put_interval_hours(:sync_library, "8")

      assert {:error, :invalid} = Scheduling.put_interval_hours(:sync_library, "soon")
      assert {:error, :invalid} = Scheduling.put_interval_hours(:sync_library, "-3")
      assert {:error, :invalid} = Scheduling.put_interval_hours(:sync_library, "2.5")

      # And the previous value survives the attempt.
      assert Scheduling.interval_hours(:sync_library) == 8
    end

    test "an absurd interval is refused, since it is a typo rather than a plan" do
      assert {:error, :invalid} = Scheduling.put_interval_hours(:sync_library, "9000")
    end

    test "an unparseable environment variable degrades to the default" do
      # A typo in compose should not stop the appliance scheduling itself.
      System.put_env("SYNC_INTERVAL_HOURS", "every-six-hours")
      on_exit(fn -> System.delete_env("SYNC_INTERVAL_HOURS") end)

      assert Scheduling.interval_hours(:sync_library) == 6
    end
  end

  describe "due?/2" do
    test "a task that has never run is due immediately" do
      # What makes a fresh install sync itself shortly after boot instead of
      # sitting idle until the first interval elapses.
      assert Scheduling.due?(:sync_library, @now)
    end

    test "a task that just ran is not due" do
      Scheduling.record_run(:sync_library)

      refute Scheduling.due?(:sync_library, DateTime.utc_now())
    end

    test "a task becomes due once its interval has elapsed" do
      Scheduling.record_run(:sync_library)
      last = Scheduling.last_run_at(:sync_library)

      refute Scheduling.due?(:sync_library, DateTime.add(last, 5 * 3600, :second))
      assert Scheduling.due?(:sync_library, DateTime.add(last, 6 * 3600, :second))
    end

    test "zero turns the schedule off, however long it has been" do
      assert :ok = Scheduling.put_interval_hours(:sync_library, "0")
      Scheduling.record_run(:sync_library)
      last = Scheduling.last_run_at(:sync_library)

      refute Scheduling.due?(:sync_library, DateTime.add(last, 365 * 24 * 3600, :second))
      assert Scheduling.next_run_at(:sync_library) == nil
    end

    test "off for one task does not turn off the other" do
      assert :ok = Scheduling.put_interval_hours(:sync_library, "0")

      refute Scheduling.due?(:sync_library, @now)
      assert Scheduling.due?(:themerrdb_refresh, @now)
    end
  end

  describe "the clock the interval is measured from" do
    test "a run started by hand resets it the same as a scheduled one" do
      # The reason record_run/1 lives in the worker rather than in the
      # heartbeat: syncing by hand at 05:58 must not be followed by a
      # scheduled sync two minutes later.
      Fanfarr.Workers.SyncLibrary.perform(%Oban.Job{args: %{}})

      refute Scheduling.due?(:sync_library, DateTime.utc_now())
    end

    test "a run is recorded even when it cancels for want of a Plex server" do
      # Otherwise an unconfigured install re-queues a doomed sync every five
      # minutes, forever.
      Fanfarr.Settings.list_settings!() |> Enum.each(&Fanfarr.Settings.delete_setting!/1)
      System.delete_env("PLEX_URL")
      System.delete_env("PLEX_TOKEN")

      assert {:cancel, :plex_not_configured} =
               Fanfarr.Workers.SyncLibrary.perform(%Oban.Job{args: %{}})

      assert Scheduling.last_run_at(:sync_library)
      refute Scheduling.due?(:sync_library, DateTime.utc_now())
    end
  end

  describe "next_run_at/1" do
    test "is the last run plus the interval" do
      Scheduling.record_run(:sync_library)
      last = Scheduling.last_run_at(:sync_library)

      assert DateTime.diff(Scheduling.next_run_at(:sync_library), last, :second) == 6 * 3600
    end

    test "is unknown until the task has run once" do
      assert Scheduling.next_run_at(:sync_library) == nil
    end
  end
end
