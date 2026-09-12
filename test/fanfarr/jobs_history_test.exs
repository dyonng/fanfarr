defmodule Fanfarr.JobsHistoryTest do
  @moduledoc """
  The Activity queue's paging and retention, against real Oban rows.

  These run the actual SQL rather than a stubbed list, because both features
  are queries: the ordering has to hold *across* pages and the retention has
  to express "keep the newest N" in a dialect with no DELETE ... LIMIT.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Jobs

  defp job!(attrs) do
    %Oban.Job{
      worker: "Fanfarr.Workers.ApplyTheme",
      queue: "apply",
      state: "completed",
      args: %{},
      attempt: 1,
      max_attempts: 3,
      errors: [],
      inserted_at: DateTime.utc_now(),
      scheduled_at: DateTime.utc_now()
    }
    |> struct!(attrs)
    |> Fanfarr.Repo.insert!()
  end

  describe "history/1" do
    test "pages newest first and reports how many pages there are" do
      for n <- 1..120, do: job!(%{args: %{"n" => n}})

      first = Jobs.history(1)
      assert first.total == 120
      assert first.pages == 3
      assert length(first.entries) == 50

      last = Jobs.history(3)
      assert length(last.entries) == 20

      # No row appears twice across the pages, which an unstable sort would
      # not guarantee -- and an unstable sort here is invisible until someone
      # notices a job on two pages and none on a third.
      ids =
        Enum.flat_map([first, Jobs.history(2), last], fn p -> Enum.map(p.entries, & &1.id) end)

      assert length(Enum.uniq(ids)) == 120
    end

    test "a page past the end lands on the last page rather than empty" do
      for _ <- 1..10, do: job!(%{})
      assert Jobs.history(99).page == 1
      assert length(Jobs.history(99).entries) == 10
    end

    test "work still running sorts ahead of everything finished, across pages" do
      # The job that matters is the oldest row in the table, so under a plain
      # id sort it would be on the last page. Sorting the loaded page instead
      # of the query would not fix that: it would only reorder the page the
      # job had already fallen off.
      running = job!(%{state: "executing", args: %{"n" => "running"}})
      for n <- 1..120, do: job!(%{args: %{"n" => n}})

      page = Jobs.history(1)
      assert hd(page.entries).id == running.id
    end

    test "the scheduler heartbeat is not listed, but a failed one is" do
      job!(%{worker: "Fanfarr.Workers.Scheduler", queue: "default"})
      failed = job!(%{worker: "Fanfarr.Workers.Scheduler", queue: "default", state: "discarded"})

      assert Enum.map(Jobs.history(1).entries, & &1.id) == [failed.id]
      assert Jobs.history(1).total == 1
    end
  end

  describe "prune_history!/1" do
    test "keeps the newest N and deletes the rest" do
      kept = for _ <- 1..10, do: job!(%{})
      assert Jobs.prune_history!(4) == 6

      remaining = Fanfarr.Repo.all(Oban.Job) |> Enum.map(& &1.id) |> Enum.sort()
      assert remaining == kept |> Enum.map(& &1.id) |> Enum.sort() |> Enum.take(-4)
    end

    test "nothing is deleted when there is less than the limit" do
      for _ <- 1..3, do: job!(%{})
      assert Jobs.prune_history!(1000) == 0
      assert Fanfarr.Repo.aggregate(Oban.Job, :count) == 3
    end

    test "work that has not finished is never deleted, however old" do
      # These are owed, not history. Pruning one loses the work rather than
      # the record of it, which is the one thing this must not do.
      owed =
        for state <- ~w(executing available scheduled retryable) do
          job!(%{state: state})
        end

      for _ <- 1..50, do: job!(%{})

      assert Jobs.prune_history!(1) > 0

      left = Fanfarr.Repo.all(Oban.Job) |> Enum.map(& &1.id)
      for job <- owed, do: assert(job.id in left)
    end

    test "heartbeats are capped on their own, so they cannot eat the budget" do
      # 288 of these land a day and none is listed. Counted against the same
      # limit they would be almost the whole of it within a week, and a
      # "keep 1000" setting would show a page or two of real work.
      for _ <- 1..400, do: job!(%{worker: "Fanfarr.Workers.Scheduler", queue: "default"})
      real = for _ <- 1..5, do: job!(%{})

      Jobs.prune_history!(1000)

      left = Fanfarr.Repo.all(Oban.Job)
      assert Enum.count(left, &(&1.worker == "Fanfarr.Workers.Scheduler")) == 200
      for job <- real, do: assert(job.id in Enum.map(left, & &1.id))
    end
  end
end
