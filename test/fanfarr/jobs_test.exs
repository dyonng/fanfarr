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

  describe "describe/2" do
    test "names the title, not the worker module", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: false})

      assert [job] = Jobs.recent()
      assert job.label == "Apply theme to WITCH WATCH"
    end

    test "a dry run says so", %{item: item} do
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id, dry_run: true})

      assert [job] = Jobs.recent()
      assert job.label == "Apply theme to WITCH WATCH (dry run)"
    end

    test "a lookup reads as a lookup", %{item: item} do
      enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id})

      assert [job] = Jobs.recent()
      assert job.label == "Look up WITCH WATCH in ThemerrDB"
    end

    test "a job about an item that no longer exists still reads as a sentence" do
      enqueue(Fanfarr.Workers.ApplyTheme, %{
        media_item_id: "00000000-0000-0000-0000-000000000000",
        dry_run: false
      })

      assert [job] = Jobs.recent()
      assert job.label == "Apply theme to an item"
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

  describe "recent/1" do
    test "work still in flight sorts above work that has finished", %{item: item} do
      # The running job is the older row, so ordering by id alone buries it.
      enqueue(Fanfarr.Workers.ApplyTheme, %{media_item_id: item.id}, "executing")
      enqueue(Fanfarr.Workers.LookupTheme, %{media_item_id: item.id}, "completed")

      assert [first, second] = Jobs.recent()
      assert first.state == "executing"
      assert second.state == "completed"
    end
  end
end
