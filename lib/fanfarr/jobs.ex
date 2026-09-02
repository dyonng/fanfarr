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
