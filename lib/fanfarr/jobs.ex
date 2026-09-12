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

  require Logger

  require Ash.Query

  @active ~w(executing available scheduled retryable)

  # The two workers a bulk selection on the Library page can queue -- the
  # only jobs "Stop" on the Activity page means, so a scheduled sync or
  # ThemerrDB refresh is never swept up by accident.
  @bulk_theme_workers ~w(Fanfarr.Workers.ApplyTheme Fanfarr.Workers.LookupTheme)

  # Plumbing rather than work. The scheduler heartbeat runs every five
  # minutes; counting it would flash "1 running" in the sidebar 288 times a
  # day, and listing it would push the jobs it exists to start off the page.
  # Shown only when it has something to report -- see `recent/1`.
  @internal_workers ~w(Fanfarr.Workers.Scheduler)

  @failed_states ~w(retryable discarded cancelled)

  # Work that is over, however it ended. The only rows retention may delete:
  # everything else is still owed.
  @finished ~w(completed discarded cancelled)

  # The one queue whose width is the operator's to choose, and the bounds it
  # is held to. One because zero would be a queue that silently never runs;
  # ten because past that the limit is YouTube's patience and the drive's,
  # not Fanfarr's, and a number that large is more likely a typo than a plan.
  @apply_concurrency_setting "apply_concurrency"
  @apply_concurrency_range 1..10

  # How many finished jobs the Activity page keeps. Counted over exactly the
  # rows that page lists, so the number means what it says -- scope it to the
  # whole table instead and the invisible heartbeats below would eat most of
  # the budget, leaving a "1000 entries" setting showing a few hundred.
  #
  # 100 because a page of 50 wants at least two; 100_000 because beyond that
  # the honest answer is that this is a dashboard, not an audit log, and the
  # application log on each item is the durable record.
  @history_setting "activity_history"
  @history_range 100..100_000
  @default_history 1000

  # Heartbeat rows are pruned separately and hard. They are invisible unless
  # they fail, 288 of them land every day, and none is worth keeping once the
  # tick after it has come and gone -- a handful is enough to prove the
  # scheduler is alive.
  @internal_history 200

  # One page of the Activity queue.
  @history_page_size 50

  # Enough completions to average out one slow download without reaching so far
  # back that a since-changed setting (a proxy, a loudness target) is still
  # weighing on the estimate.
  @duration_sample 50

  # attempted_at and the three finish columns are what turn a state badge into
  # "queued 4 minutes ago, took 12s". Oban writes a different one depending on
  # how a job ended, so all three are read and `finished_at/1` picks.
  @fields [
    :id,
    :worker,
    :state,
    :queue,
    :args,
    :attempt,
    :max_attempts,
    :errors,
    :inserted_at,
    :scheduled_at,
    :attempted_at,
    :completed_at,
    :cancelled_at,
    :discarded_at
  ]

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
          where: j.worker not in ^@internal_workers,
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

  Jobs are bucketed by worker, because an apply and a ThemerrDB lookup differ
  by orders of magnitude -- one downloads audio, re-encodes it for loudness
  and then waits on Plex, the other asks a JSON endpoint one question.
  Averaging the two together produced an estimate that was wrong for both.
  Each bucket contributes `pending x its own mean duration`; the queue's
  concurrency divides its total, and the queues run alongside each other, so
  the answer is the slowest queue rather than the sum.

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
      |> Enum.group_by(fn {{_worker, queue}, _count} -> queue end)
      |> Enum.map(fn {queue, buckets} -> queue_seconds(queue, buckets, means) end)
      |> then(fn per_queue ->
        # Any bucket without a measurement makes the whole answer a guess.
        if Enum.any?(per_queue, &is_nil/1), do: nil, else: Enum.max(per_queue, fn -> nil end)
      end)
    end
  end

  defp queue_seconds(queue, buckets, means) do
    work =
      Enum.reduce_while(buckets, 0, fn {{worker, _q}, count}, acc ->
        case Map.get(means, worker) do
          nil -> {:halt, nil}
          mean -> {:cont, acc + count * mean}
        end
      end)

    if work, do: ceil(work / concurrency(queue)), else: nil
  end

  @doc """
  How many jobs of a queue run at once.

  From the same config the supervisor hands Oban rather than `Oban.config/0`:
  the test environment runs `testing: :manual`, where the running instance
  reports no queues at all and every estimate would divide by one. The
  :apply queue additionally honours the operator's setting, which is where
  the running limit actually comes from once they have changed it.
  """
  @spec concurrency(atom()) :: pos_integer()
  def concurrency(:apply), do: apply_concurrency()

  def concurrency(queue), do: compiled_concurrency(queue)

  defp compiled_concurrency(queue) do
    :fanfarr
    |> Application.fetch_env!(Oban)
    |> Keyword.get(:queues, [])
    |> Keyword.get(queue, 1)
    |> max(1)
  end

  @doc """
  How many themes download and apply at once.

  Resolved like every other setting -- dashboard override, environment
  variable, then the compiled default -- and clamped, so a value typed into
  the environment cannot start the appliance with a queue width of 400.
  """
  @spec apply_concurrency() :: pos_integer()
  def apply_concurrency do
    case Fanfarr.Config.get(@apply_concurrency_setting) do
      nil -> compiled_concurrency(:apply)
      value -> parse_concurrency(value) || compiled_concurrency(:apply)
    end
  end

  @doc "The bounds the apply queue is held to, for the form to show and enforce."
  @spec apply_concurrency_range() :: Range.t()
  def apply_concurrency_range, do: @apply_concurrency_range

  @doc """
  Stores the apply queue's width and applies it to the running queue.

  Oban can be re-scaled at runtime even though it cannot be re-crontabbed, so
  this takes effect on the jobs already waiting rather than at the next
  restart -- raising it mid-run is the whole point. It is stored as well, and
  `Fanfarr.Jobs.oban_config/0` reads it back at boot.
  """
  @spec put_apply_concurrency(String.t()) :: :ok | {:error, :invalid}
  def put_apply_concurrency(value) do
    case parse_concurrency(to_string(value)) do
      nil ->
        {:error, :invalid}

      limit ->
        Fanfarr.Settings.put_setting!(@apply_concurrency_setting, Integer.to_string(limit))
        scale_apply_queue(limit)
        :ok
    end
  end

  @doc """
  How many finished jobs the Activity page keeps.

  Resolved like every other setting and clamped, so a hand-edited value cannot
  ask this to hold a million rows in SQLite.
  """
  @spec history_limit() :: pos_integer()
  def history_limit do
    case Fanfarr.Config.get(@history_setting) do
      nil -> @default_history
      value -> parse_history(value) || @default_history
    end
  end

  @doc "The bounds the history is held to, and its default, for the form."
  @spec history_range() :: Range.t()
  def history_range, do: @history_range

  @spec default_history() :: pos_integer()
  def default_history, do: @default_history

  @doc "Stores how many finished jobs to keep, and applies it immediately."
  @spec put_history_limit(String.t()) :: :ok | {:error, :invalid}
  def put_history_limit(value) do
    case parse_history(to_string(value)) do
      nil ->
        {:error, :invalid}

      limit ->
        Fanfarr.Settings.put_setting!(@history_setting, Integer.to_string(limit))
        # Applied now rather than at the next heartbeat: lowering it is
        # usually someone reacting to a page that has become unwieldy, and
        # waiting five minutes to see it take effect reads as not having
        # worked.
        prune_history!()
        :ok
    end
  end

  defp parse_history(value) do
    case Integer.parse(String.trim(value)) do
      {limit, ""} -> if limit in @history_range, do: limit, else: nil
      _ -> nil
    end
  end

  @doc """
  Deletes finished jobs beyond what the operator asked to keep.

  Two rules, because the table holds two populations. The rows Activity lists
  are capped at `history_limit/0`. The scheduler heartbeats -- invisible
  unless they fail, 288 a day -- are capped separately and much harder, or
  they would be most of the table within a week while contributing nothing to
  the page the limit is about.

  Only finished work is ever deleted. Anything executing, available, scheduled
  or retryable is still owed, and pruning it would lose work rather than
  history.

  Returns the number of rows deleted.
  """
  @spec prune_history!() :: non_neg_integer()
  def prune_history!(limit \\ nil) do
    keep = limit || history_limit()

    trim(from(j in visible(), where: j.state in ^@finished), keep) +
      trim(
        from(j in Oban.Job, where: j.worker in ^@internal_workers and j.state in ^@finished),
        @internal_history
      )
  end

  # SQLite has no DELETE ... ORDER BY LIMIT, so the cut-off is read first and
  # the delete is a plain range. `offset: keep` lands on the newest row that
  # is *not* being kept, so everything at or below its id goes; when the scope
  # holds fewer rows than the limit there is no such row and nothing to do.
  defp trim(scope, keep) do
    cutoff =
      Fanfarr.Repo.one(
        from j in scope, order_by: [desc: j.id], offset: ^keep, limit: 1, select: j.id
      )

    case cutoff do
      nil ->
        0

      id ->
        {deleted, _} = Fanfarr.Repo.delete_all(from(j in scope, where: j.id <= ^id))
        deleted
    end
  end

  @doc """
  Starts Oban with the operator's settings applied.

  Called by the supervisor as an MFA rather than being evaluated into a child
  tuple, because the settings this reads live in the database and the database
  is a child that has to have started first. See `Fanfarr.Application`.
  """
  def start_oban do
    config = oban_config()

    Logger.info("[fanfarr] apply queue starting at #{config[:queues][:apply]} concurrent jobs")

    :fanfarr
    |> Application.fetch_env!(:ash_domains)
    |> AshOban.config(config)
    |> Oban.start_link()
  end

  @doc """
  The Oban config the supervisor should start, with the operator's apply width
  applied.

  Falls back to the compiled config if the setting cannot be read: an
  unreadable preference is worth defaulting, not worth refusing to boot over.
  """
  @spec oban_config() :: keyword()
  def oban_config do
    base = Application.fetch_env!(:fanfarr, Oban)

    try do
      Keyword.update!(base, :queues, &Keyword.put(&1, :apply, apply_concurrency()))
    rescue
      error ->
        Logger.warning(
          "[fanfarr] could not read the apply concurrency setting " <>
            "(#{inspect(error)}); starting at the default"
        )

        base
    end
  end

  # Queues only exist to be scaled when they are running, and under
  # `testing: :manual` -- the whole test suite -- they are not.
  defp scale_apply_queue(limit) do
    if is_nil(Application.fetch_env!(:fanfarr, Oban)[:testing]) do
      Oban.scale_queue(queue: :apply, limit: limit)
    end

    :ok
  end

  defp parse_concurrency(value) do
    case Integer.parse(String.trim(value)) do
      {limit, ""} -> if limit in @apply_concurrency_range, do: limit, else: nil
      _ -> nil
    end
  end

  defp pending_by_bucket do
    Fanfarr.Repo.all(
      from j in Oban.Job,
        where: j.worker in ^@bulk_theme_workers,
        where: j.state in ^@active,
        select: {j.worker, j.queue}
    )
    |> Enum.frequencies_by(fn {worker, queue} -> {worker, String.to_existing_atom(queue)} end)
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
        select: {j.worker, j.attempted_at, j.completed_at}
    )
    |> Enum.group_by(
      fn {worker, _, _} -> worker end,
      fn {_, started, finished} ->
        max(NaiveDateTime.diff(finished, started, :millisecond), 0) / 1000
      end
    )
    |> Map.new(fn {bucket, durations} -> {bucket, Enum.sum(durations) / length(durations)} end)
  end

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
  What the queue is working on and what it will pick up next, in that order.

  For the layout's queue widget rather than the Activity page: only work that
  is still outstanding, oldest first within each state, because a queue is
  read in the order it will be worked rather than newest-first. Running jobs
  lead regardless of age.

  `limit` caps the rows; `total_active/0` says how many there really are, so
  the widget can say "and 40 more" rather than implying the list is all of it.
  """
  @spec active(non_neg_integer()) :: [map()]
  def active(limit \\ 8) do
    Fanfarr.Repo.all(
      from j in Oban.Job,
        where: j.state in ^@active,
        where: j.worker not in ^@internal_workers,
        order_by: [asc: fragment("? != 'executing'", j.state), asc: j.id],
        limit: ^limit,
        select: [:id, :worker, :state, :queue, :args, :attempt, :max_attempts, :inserted_at]
    )
    |> decorate()
  end

  @doc "How much outstanding work there is, counting what `active/1` cropped."
  @spec total_active() :: non_neg_integer()
  def total_active do
    Fanfarr.Repo.aggregate(
      from(j in Oban.Job,
        where: j.state in ^@active,
        where: j.worker not in ^@internal_workers
      ),
      :count
    )
  end

  @doc """
  Jobs worth showing, newest first, with a human line for each.

  Running and waiting work comes first however old it is: a job still going is
  more interesting than a job that finished a second ago, and ordering purely
  by id buries it under whatever has completed since.
  """
  @spec recent(non_neg_integer()) :: [map()]
  def recent(limit \\ 40) do
    Fanfarr.Repo.all(
      from(j in visible(), order_by: [desc: j.id], limit: ^limit, select: ^@fields)
    )
    |> decorate()
    |> Enum.sort_by(&{&1.state not in @active, -&1.id})
  end

  @doc """
  One page of the queue, newest first, with what is still running pulled to
  the top of page one.

  Anything unfinished sorts ahead of everything finished however old it is,
  because a job still going is the thing this page exists to show and ordering
  purely by id buries it under whatever completed while it ran. That ordering
  is done in SQL rather than over the loaded rows: sorting a page after
  slicing it only sorts within that page, so a long-running job would slide
  further back with every completion until it fell off page one entirely.
  """
  @spec history(pos_integer()) :: %{
          entries: [map()],
          page: pos_integer(),
          pages: pos_integer(),
          total: non_neg_integer(),
          page_size: pos_integer()
        }
  def history(page \\ 1) do
    total = Fanfarr.Repo.aggregate(visible(), :count)
    pages = max(ceil(total / @history_page_size), 1)
    page = page |> max(1) |> min(pages)

    entries =
      Fanfarr.Repo.all(
        from j in visible(),
          order_by: [
            asc: fragment("case when ? then 0 else 1 end", j.state in ^@active),
            desc: j.id
          ],
          limit: ^@history_page_size,
          offset: ^((page - 1) * @history_page_size),
          select: ^@fields
      )
      |> decorate()

    %{entries: entries, page: page, pages: pages, total: total, page_size: @history_page_size}
  end

  @doc "Rows per page of the Activity queue."
  @spec history_page_size() :: pos_integer()
  def history_page_size, do: @history_page_size

  # The rows the Activity page lists, and the set every count here is over.
  defp visible do
    from j in Oban.Job, where: j.worker not in ^@internal_workers or j.state in ^@failed_states
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
      {"ApplyTheme", _args} ->
        "Apply theme"

      {"LookupTheme", _args} ->
        "Look up in ThemerrDB"

      {"SyncSection", _args} ->
        "Sync a library section from Plex"

      {"SyncLibrary", _args} ->
        "Sync the library list from Plex"

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
  # A job row is a worker module and an args map, neither of which reads as
  # anything. This is what turns both into a line about a title.
  defp decorate(jobs) do
    titles = titles_for(jobs)

    Enum.map(jobs, fn job ->
      id = subject_id(job)

      job
      |> Map.put(:label, describe(job))
      |> Map.put(:item_id, id)
      |> Map.put(:item_title, id && Map.get(titles, id))
    end)
  end

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
