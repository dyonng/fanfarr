defmodule Fanfarr.JobsTest do
  @moduledoc "What the queue is doing, in words about titles rather than modules."
  use Fanfarr.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Fanfarr.Jobs

  setup do
    section =
      Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "WITCH WATCH",
        kind: :show
      })

    %{item: item}
  end

  defp enqueue(worker, args, state \\ "available") do
    {:ok, job} = worker.new(args) |> Oban.insert()

    if state != "available" do
      Fanfarr.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: state]
      )
    end

    job
  end

  describe "the action and its subject" do
    test "the title is carried separately, so the table can link it", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false})

      assert [job] = Jobs.recent()
      assert job.label == "Apply theme"
      assert job.item_title == "WITCH WATCH"
      assert job.item_id == item.id
    end

    test "a dry run says so", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: true})

      assert [job] = Jobs.recent()
      assert job.label == "Apply theme (dry run)"
    end

    test "a lookup reads as a lookup", %{item: item} do
      enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id})

      assert [job] = Jobs.recent()
      assert job.label == "Look up in ThemerrDB"
      assert job.item_title == "WITCH WATCH"
    end

    test "a job whose item is gone keeps the id and has no title" do
      enqueue(Fanfarr.Workers.ApplyTheme, %{
        media_item_id: "00000000-0000-0000-0000-000000000000",
        dry_run: false
      })

      assert [job] = Jobs.recent()
      assert job.label == "Apply theme"
      assert job.item_title == nil
      assert job.item_id == "00000000-0000-0000-0000-000000000000"
    end

    test "a job about no particular item has neither", %{item: _item} do
      enqueue(Fanfarr.Workers.RefreshThemerr, %{})

      assert [job] = Jobs.recent()
      assert job.label == "Refresh ThemerrDB entries"
      assert job.item_id == nil
      assert job.item_title == nil
    end

    test "an unrecognised worker falls back to its short name" do
      assert Jobs.describe(%{worker: "Fanfarr.Workers.Whatever", args: %{}}) == "Whatever"
    end
  end

  describe "summary/0" do
    test "an empty queue is not busy" do
      assert Jobs.summary() == %{running: 0, queued: 0}
      refute Jobs.busy?(Jobs.summary())
    end

    test "separates what is running from what is waiting", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "executing")
      enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id})

      assert %{running: 1, queued: 1} = Jobs.summary()
      assert Jobs.busy?(Jobs.summary())
    end

    test "finished work is neither running nor waiting", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      assert %{running: 0, queued: 0} = Jobs.summary()
    end

    test "a retryable job is still waiting, not forgotten", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "retryable")

      assert %{queued: 1} = Jobs.summary()
    end
  end

  describe "eta_seconds/0" do
    # A completed job with a known runtime, so the estimate has something real
    # to measure rather than a constant baked into the test.
    defp completed(worker, args, seconds) do
      job = enqueue(worker, args, "completed")
      started = NaiveDateTime.utc_now() |> NaiveDateTime.add(-seconds, :second)

      Fanfarr.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [attempted_at: started, completed_at: NaiveDateTime.utc_now()]
      )

      job
    end

    test "nothing outstanding, nothing to estimate" do
      assert Jobs.eta_seconds() == nil
    end

    test "no history to measure against says so rather than guessing", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false})

      assert Jobs.eta_seconds() == nil
    end

    test "divides the remaining work by the queue's concurrency", %{item: item} do
      completed(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false}, 30)

      for n <- 1..4 do
        enqueue(Fanfarr.Workers.ApplyTheme, %{
          media_item_id: item.id,
          dry_run: false,
          theme_url: "https://example.com/#{n}"
        })
      end

      # Four jobs of ~30s across a queue that runs two at a time.
      assert_in_delta Jobs.eta_seconds(), 60, 2
    end

    test "a dry run is not costed as if it were a download", %{item: item} do
      completed(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false}, 60)
      completed(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: true}, 2)

      for n <- 1..4 do
        enqueue(Fanfarr.Workers.ApplyTheme, %{
          media_item_id: item.id,
          dry_run: true,
          theme_url: "https://example.com/#{n}"
        })
      end

      # Four dry runs at ~2s over two slots is seconds, not minutes. Averaging
      # the real apply in would have said 62.
      assert_in_delta Jobs.eta_seconds(), 4, 2
    end

    test "queues run alongside each other, so the slowest one decides", %{item: item} do
      completed(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false}, 60)
      completed(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id}, 1)

      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false})

      for n <- 1..10 do
        enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id, nonce: n})
      end

      # The applies take ~30s; ten lookups over two slots take ~5s. Adding
      # them would claim 35.
      assert_in_delta Jobs.eta_seconds(), 30, 2
    end
  end

  describe "bulk_theme_work_pending?/0 and cancel_bulk_theme_work!/0" do
    test "nothing pending when the queue is empty" do
      refute Jobs.bulk_theme_work_pending?()
      assert Jobs.cancel_bulk_theme_work!() == 0
    end

    test "cancels available, scheduled, retryable and executing apply/lookup jobs", %{
      item: item
    } do
      for state <- ["available", "scheduled", "retryable", "executing"] do
        # theme_url varies so each lands as its own row rather than colliding
        # with ApplyTheme's own uniqueness (media_item_id + dry_run + theme_url).
        enqueue(
          Fanfarr.Workers.ApplyTheme,
          %{media_item_id: item.id, dry_run: true, theme_url: "https://example.com/#{state}"},
          state
        )
      end

      enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id}, "available")

      assert Jobs.bulk_theme_work_pending?()
      assert Jobs.cancel_bulk_theme_work!() == 5

      states = Fanfarr.Repo.all(from(j in Oban.Job, select: j.state))
      assert Enum.all?(states, &(&1 == "cancelled"))
      refute Jobs.bulk_theme_work_pending?()
    end

    test "leaves finished work and other workers alone", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")
      enqueue(Fanfarr.Workers.RefreshThemerr, %{}, "available")
      enqueue(Fanfarr.Workers.SyncSection, %{section_id: "x"}, "available")

      refute Jobs.bulk_theme_work_pending?()
      assert Jobs.cancel_bulk_theme_work!() == 0

      states = Fanfarr.Repo.all(from(j in Oban.Job, select: j.state))
      assert "completed" in states
      assert Enum.count(states, &(&1 == "available")) == 2
    end
  end

  describe "recent/1" do
    test "work still in flight sorts above work that has finished", %{item: item} do
      # The running job is the older row, so ordering by id alone buries it.
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "executing")
      enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id}, "completed")

      assert [first, second] = Jobs.recent()
      assert first.state == "executing"
      assert second.state == "completed"
    end

    test "the scheduler heartbeat is not listed as activity", %{item: item} do
      # It runs 288 times a day. Listed, it would push every job it exists to
      # start off a 40-row page.
      enqueue(Fanfarr.Workers.Scheduler, %{}, "completed")
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "completed")

      workers = Jobs.recent() |> Enum.map(& &1.worker)

      assert workers == ["Fanfarr.Workers.ApplyTheme"]
    end

    test "a heartbeat that failed is listed, since that is worth knowing" do
      enqueue(Fanfarr.Workers.Scheduler, %{}, "discarded")

      assert [%{worker: "Fanfarr.Workers.Scheduler"}] = Jobs.recent()
    end
  end

  describe "summary/0 and the heartbeat" do
    test "a queued heartbeat is not counted as work" do
      # Otherwise the sidebar flashes "1 queued" every five minutes forever.
      enqueue(Fanfarr.Workers.Scheduler, %{})

      assert %{running: 0, queued: 0} = Jobs.summary()
    end
  end

  describe "apply concurrency" do
    test "defaults to the compiled queue width" do
      assert Jobs.apply_concurrency() == 2
      assert Jobs.concurrency(:apply) == 2
    end

    test "a saved value wins, and is what the ETA divides by" do
      assert :ok = Jobs.put_apply_concurrency("6")

      assert Jobs.apply_concurrency() == 6
      assert Jobs.concurrency(:apply) == 6
    end

    test "the boot config carries the saved value into the queue" do
      assert :ok = Jobs.put_apply_concurrency("5")

      assert Jobs.oban_config()[:queues][:apply] == 5
    end

    test "other queues are not the operator's to widen" do
      # :themerrdb in particular -- a community-run static host does not get
      # to be hammered because someone raised a number.
      assert :ok = Jobs.put_apply_concurrency("10")

      assert Jobs.concurrency(:themerrdb) == 2
      assert Jobs.oban_config()[:queues][:themerrdb] == 2
    end

    test "a value outside the range is refused rather than clamped silently" do
      assert {:error, :invalid} = Jobs.put_apply_concurrency("0")
      assert {:error, :invalid} = Jobs.put_apply_concurrency("400")
      assert {:error, :invalid} = Jobs.put_apply_concurrency("lots")

      assert Jobs.apply_concurrency() == 2
    end

    test "an out-of-range environment variable degrades to the default" do
      System.put_env("APPLY_CONCURRENCY", "400")
      on_exit(fn -> System.delete_env("APPLY_CONCURRENCY") end)

      assert Jobs.apply_concurrency() == 2
    end
  end
end
