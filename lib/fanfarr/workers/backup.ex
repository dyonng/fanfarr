defmodule Fanfarr.Workers.Backup do
  @moduledoc """
  Takes a database snapshot on its own job rather than inside the heartbeat
  that asked for it.

  A snapshot reads the whole database. The heartbeat runs every five minutes and
  its job is to enqueue what is due, so doing the reading there would hold up the
  enqueueing of everything else behind a copy of a database that may be large.

  ## Two triggers

  `"auto"` is the scheduled one, and it asks again at execution time whether a
  snapshot is still due. That re-check is the real protection against doing the
  work twice: a queued duplicate finds nothing to do rather than taking a second
  copy.

  `"manual"` is the operator pressing **Back up now**. It ignores both the
  interval and the switch, because the switch is about what happens unattended,
  not about whether a person is allowed to do it by hand.

  ## Why the deduplication is written out rather than declared

  Oban's `unique` option is the idiomatic way to say "do not stack these", and
  it is deliberately not used here. Measured, two inserts of this worker with
  identical args both landed: the Lite engine builds its conflict key from
  `changeset.get_field(:args)`, and atom-keyed args extract to an empty map, so
  the key it searched for matched nothing and every insert looked unique.

  So the check is explicit and visible instead -- ask the job table whether a
  backup is already unfinished. Narrower than it looks, and no less safe: one
  snapshot at a time is the whole requirement, and a double press producing two
  snapshots a second apart would be harmless anyway, since the names differ and
  the rotation keeps a count.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  @unfinished ~w(available scheduled executing retryable)

  @doc "Queues a snapshot if one is due and none is already unfinished."
  @spec enqueue_if_due() :: {:ok, Oban.Job.t()} | :ok
  def enqueue_if_due do
    if Fanfarr.Backup.due?() and not pending?(), do: enqueue("auto"), else: :ok
  end

  @doc """
  Queues a snapshot now, whatever the schedule or the switch says.

  The manual path. A snapshot is additive and reversible, which is the whole
  difference between this and an apply.
  """
  @spec enqueue_now() :: {:ok, Oban.Job.t()} | :ok
  def enqueue_now do
    if pending?(), do: :ok, else: enqueue("manual")
  end

  @doc "Whether a backup is already queued or running."
  @spec pending?() :: boolean()
  def pending? do
    # `inspect/1`, not `to_string/1`: a module atom stringifies with an
    # `Elixir.` prefix, and Oban stores the bare name -- so comparing against
    # `to_string(__MODULE__)` matched no row at all, and the check silently
    # always answered "not pending".
    Fanfarr.Repo.exists?(
      from j in Oban.Job,
        where: j.worker == ^inspect(__MODULE__),
        where: j.state in ^@unfinished
    )
  end

  defp enqueue(trigger) do
    case new(%{trigger: trigger}) |> Oban.insert() do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trigger" => "auto"}}) do
    if Fanfarr.Backup.due?(), do: snapshot(), else: :ok
  end

  def perform(%Oban.Job{args: %{"trigger" => "manual"}}), do: snapshot()

  defp snapshot do
    case Fanfarr.Backup.snapshot() do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
