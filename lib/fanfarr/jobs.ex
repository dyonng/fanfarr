defmodule Fanfarr.Jobs do
  @moduledoc """
  What the background queue is doing, in terms the dashboard can render.

  Everything the operator asks for is a job: applying a theme, syncing a
  section, asking ThemerrDB. That is what makes it safe to click a button and
  navigate away -- the work is already in the database and Oban owns it from
  there, so nothing depends on the page staying open. It also means the queue
  is the only honest answer to "is it doing anything?", and until there was
  somewhere to see it, the answer was a spinner on whichever page happened to
  have started the work.

  Job rows carry a worker module and an args map, neither of which reads as
  anything. `describe/1` turns them into a line about a title.
  """
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  @active ~w(executing available scheduled retryable)

  # The two workers a bulk selection on the Library page can queue -- the
  # only jobs "Stop" on the Activity page means, so a scheduled sync or
  # ThemerrDB refresh is never swept up by accident.
  @bulk_theme_workers ~w(Fanfarr.Workers.ApplyTheme Fanfarr.Workers.LookupTheme)

  # Enough completions to average out one slow download without reaching so far
  # back that a since-changed setting (a proxy, a loudness target) is still
  # weighing on the estimate.
  @duration_sample 50

  @type summary :: %{running: non_neg_integer(), queued: non_neg_integer()}

  @doc """
  Counts of what is running now and what is waiting.

  Cheap enough to poll: two integers out of one grouped query.
  """
  @spec summary() :: summary()
  def summary do
    counts =
      Fanfarr.Repo.all(
        from j in Oban.Job,
          where: j.state in ^@active,
          group_by: j.state,
          select: {j.state, count(j.id)}
      )
      |> Map.new()

    %{
      running: Map.get(counts, "executing", 0),
      queued:
        Map.get(counts, "available", 0) + Map.get(counts, "scheduled", 0) +
          Map.get(counts, "retryable", 0)
    }
  end

  @spec busy?(summary()) :: boolean()
  def busy?(%{running: running, queued: queued}), do: running + queued > 0

  @doc """
  Whether a bulk apply or ThemerrDB lookup is running or waiting, for the
  Activity page to decide whether "Stop" has anything to do.
  """
  @spec bulk_theme_work_pending?() :: boolean()
  def bulk_theme_work_pending? do
    Fanfarr.Repo.exists?(
      from j in Oban.Job,
        where: j.worker in ^@bulk_theme_workers,
        where: j.state in ^@active
    )
  end

  @doc """
  Roughly how much longer the outstanding work will take, in seconds.

  `nil` when there is nothing outstanding, or when this install has not
  finished enough comparable jobs to say anything honest. A guess dressed up
  as a countdown is worse than no countdown: the first bulk run on a new
  install is exactly when there is no history to measure, and exactly when a
  made-up number would be believed.

  ## How it is arrived at

  Jobs are bucketed by worker *and* by dry-run flag, because those differ by
  orders of magnitude -- a dry run resolves a URL and a path and stops, while
  a real apply downloads audio, re-encodes it for loudness, and then waits on
  Plex. Averaging the two together produced an estimate that was wrong for
  both. Each bucket contributes `pending x its own mean duration`; the
  queue's concurrency divides its total, and the queues run alongside each
  other, so the answer is the slowest queue rather than the sum.

  Durations come from `attempted_at` to `completed_at` on recent completions,
  which is the time the job actually spent running rather than the time it
  spent waiting behind other jobs -- the queue depth accounts for the waiting
  already.
  """
  @spec eta_seconds() :: non_neg_integer() | nil
  def eta_seconds do
    pending = pending_by_bucket()

    if pending == %{} do
      nil
    else
      means = mean_durations()

      pending
      |> Enum.group_by(fn {{_worker, _dry_run, queue}, _count} -> queue end)
      |> Enum.map(fn {queue, buckets} -> queue_seconds(queue, buckets, means) end)
      |> then(fn per_queue ->
        # Any bucket without a measurement makes the whole answer a guess.
        if Enum.any?(per_queue, &is_nil/1), do: nil, else: Enum.max(per_queue, fn -> nil end)
      end)
    end
  end

  defp queue_seconds(queue, buckets, means) do
    work =
      Enum.reduce_while(buckets, 0, fn {{worker, dry_run, _q}, count}, acc ->
        case Map.get(means, {worker, dry_run}) do
          nil -> {:halt, nil}
          mean -> {:cont, acc + count * mean}
        end
      end)

    if work, do: ceil(work / concurrency(queue)), else: nil
  end

  # From the same config the supervisor hands Oban, rather than Oban.config/0:
  # the test environment runs `testing: :manual`, where the running instance
  # reports no queues at all and every estimate would divide by one.
  defp concurrency(queue) do
    :fanfarr
    |> Application.fetch_env!(Oban)
    |> Keyword.get(:queues, [])
    |> Keyword.get(queue, 1)
    |> max(1)
  end

  defp pending_by_bucket do
    Fanfarr.Repo.all(
      from j in Oban.Job,
        where: j.worker in ^@bulk_theme_workers,
        where: j.state in ^@active,
        select: {j.worker, fragment("json_extract(?, ?)", j.args, "$.dry_run"), j.queue}
    )
    |> Enum.frequencies_by(fn {worker, dry_run, queue} ->
      {worker, truthy(dry_run), String.to_existing_atom(queue)}
    end)
  end

  # Only completions count. A cancelled or discarded job says nothing about
  # how long the work takes, and a retried one has already been counted.
  defp mean_durations do
    Fanfarr.Repo.all(
      from j in Oban.Job,
        where: j.worker in ^@bulk_theme_workers,
        where: j.state == "completed",
        where: not is_nil(j.attempted_at) and not is_nil(j.completed_at),
        order_by: [desc: j.id],
        limit: @duration_sample,
        select:
          {j.worker, fragment("json_extract(?, ?)", j.args, "$.dry_run"), j.attempted_at,
           j.completed_at}
    )
    |> Enum.group_by(
      fn {worker, dry_run, _, _} -> {worker, truthy(dry_run)} end,
      fn {_, _, started, finished} ->
        max(NaiveDateTime.diff(finished, started, :millisecond), 0) / 1000
      end
    )
    |> Map.new(fn {bucket, durations} -> {bucket, Enum.sum(durations) / length(durations)} end)
  end

  # SQLite hands back 1/0 for a JSON boolean, and nil where the key is absent
  # -- ApplyTheme defaults dry_run to true when it is missing, so nil is true.
  defp truthy(nil), do: true
  defp truthy(0), do: false
  defp truthy(false), do: false
  defp truthy(_), do: true

  @doc """
  Cancels every apply and ThemerrDB-lookup job that has not finished --
  available, scheduled, retryable, or executing right now.

  An executing job is killed outright, not just marked, and the process gets
  no chance to run its own cleanup on the way out -- Oban terminates it with
  an untrapped exit. That is still safe here because `Themes.Writer.place/2`
  never writes to the real destination path directly: it stages the file
  under a hidden temporary name in the same directory and only `File.rename/2`s
  it into place once it is fully on disk. A kill can only ever land before
  that rename (nothing visible yet) or after it (already a complete file); it
  can strand a scratch download in `System.tmp_dir!/0` or a stray hidden
  `.part` file next to the media, but it cannot leave Plex looking at a
  half-written theme.mp3.

  Returns how many were cancelled.
  """
  @spec cancel_bulk_theme_work!() :: non_neg_integer()
  def cancel_bulk_theme_work! do
    {:ok, count} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where: j.worker in ^@bulk_theme_workers,
          where: j.state in ^@active
        )
      )

    count
  end

  @doc """
  Jobs worth showing, newest first, with a human line for each.

  Running and waiting work comes first however old it is: a job still going is
  more interesting than a job that finished a second ago, and ordering purely
  by id buries it under whatever has completed since.
  """
  @spec recent(non_neg_integer()) :: [map()]
  def recent(limit \\ 40) do
    jobs =
      Fanfarr.Repo.all(
        from j in Oban.Job,
          order_by: [desc: j.id],
          limit: ^limit,
          select: [
            :id,
            :worker,
            :state,
            :queue,
            :args,
            :attempt,
            :max_attempts,
            :errors,
            :inserted_at
          ]
      )

    titles = titles_for(jobs)

    jobs
    |> Enum.map(fn job ->
      id = subject_id(job)

      job
      |> Map.put(:label, describe(job))
      |> Map.put(:item_id, id)
      |> Map.put(:item_title, id && Map.get(titles, id))
    end)
    |> Enum.sort_by(&{&1.state not in @active, -&1.id})
  end

  @doc """
  What the job is doing, with no mention of what it is doing it to.

  The title is carried separately so the table can put it in its own column
  and link it: folded into the sentence it is unclickable, and columns of
  running prose do not scan.
  """
  @spec describe(map()) :: String.t()
  def describe(job) do
    case {short_worker(job.worker), job.args} do
      {"ApplyTheme", args} ->
        if args["dry_run"], do: "Apply theme (dry run)", else: "Apply theme"

      {"LookupTheme", _args} ->
        "Look up in ThemerrDB"

      {"SyncSection", _args} ->
        "Sync a library section from Plex"

      {"RefreshThemerr", _args} ->
        "Refresh ThemerrDB entries"

      {worker, _args} ->
        worker
    end
  end

  @doc "The media item a job is about, when it is about one."
  @spec subject_id(map()) :: String.t() | nil
  def subject_id(%{args: args}) when is_map(args), do: args["media_item_id"]
  def subject_id(_), do: nil

  @doc "The worker module without its namespace."
  @spec short_worker(String.t()) :: String.t()
  def short_worker(worker) when is_binary(worker), do: worker |> String.split(".") |> List.last()
  def short_worker(_), do: "job"

  # One query for every item mentioned by the batch, rather than one per job.
  defp titles_for(jobs) do
    ids =
      jobs
      |> Enum.map(&subject_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Fanfarr.Library.MediaItem
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :title])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.title})
    end
  end
end
