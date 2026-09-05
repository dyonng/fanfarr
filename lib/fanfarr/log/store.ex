defmodule Fanfarr.Log.Store do
  @moduledoc """
  The log, kept in the database so it survives a restart.

  `Fanfarr.Log.Buffer` holds the last few hundred entries in memory and is
  what the bug-report bundle reads; it is gone the moment the container is
  replaced, which is exactly when someone wants to know what happened just
  before. This is the same stream written down.

  ## Nothing on this path may log

  This is the rule the whole module is shaped around. Ecto logs every query it
  runs, that line is captured by the buffer, and the buffer feeds this store
  -- so a query here produces a log line, which produces a query, which
  produces a log line. It does not spin in a single stack, which would be
  obvious; it feeds itself one flush at a time, forever, filling the log with
  the log writing the log. `Fanfarr.Diagnostics.Redactor` carries the same
  rule for the same reason.

  So every database call in this module passes `log: false`, and the retention
  setting is read once at boot and updated when it is saved rather than read
  per flush. A flush therefore produces no log lines at all, and the cycle has
  nowhere to start.

  ## Batched, bounded, lossy

  Writes are batched on a timer rather than done per line: SQLite serialises
  writers, and one transaction per log line on a box that is also writing
  theme files is a bad trade for a debugging aid. A crash loses at most a
  second of entries, and the pending list is capped so a database that has
  gone away cannot turn the log into a memory leak.
  """
  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Fanfarr.Log.Entry

  @flush_ms 1_000

  # The default the operator can change, and the bounds it is held to. Ten
  # million lines of log in a SQLite file next to the library is not a
  # debugging aid, and zero would be a setting that quietly turns the feature
  # off while the page still says "Logs".
  @default_retention 5_000
  @retention_range 100..200_000
  @retention_setting "log_retention_entries"

  # A cap on what one flush will carry, so a stalled writer or an unreachable
  # database drops the oldest pending lines instead of growing without bound.
  @max_pending 10_000

  @type entry :: Fanfarr.Log.Buffer.entry()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Queues an entry to be written.

  A cast, and deliberately tolerant of this process not existing: the buffer
  attaches to the logger before the repo has started, so the first few lines
  of a boot are captured in memory and simply not persisted. `GenServer.cast`
  to an unregistered name is already a no-op, so there is nothing to guard.
  """
  @spec append(entry()) :: :ok
  def append(entry), do: GenServer.cast(__MODULE__, {:append, entry})

  @doc """
  Persisted entries, newest first.

  `:level` keeps entries at or above a severity, `:query` keeps those whose
  message or source contains it, and `:limit` caps the rows returned. All
  three are pushed into SQL: a text search that only reached the rendered
  window would be a search that quietly misses things.
  """
  @spec entries(keyword()) :: [entry()]
  def entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    Entry
    |> filter_level(Keyword.get(opts, :level))
    |> filter_query(Keyword.get(opts, :query))
    |> then(&from(e in &1, order_by: [desc: e.id], limit: ^limit))
    |> Fanfarr.Repo.all(log: false)
    |> Enum.map(&to_entry/1)
  catch
    # The console asking for history must never be the thing that takes the
    # page down -- a missing table on a half-migrated boot included.
    _, _ -> []
  end

  @doc "How many entries are held, by level."
  @spec counts() :: %{atom() => non_neg_integer()}
  def counts do
    from(e in Entry, group_by: e.level, select: {e.level, count(e.id)})
    |> Fanfarr.Repo.all(log: false)
    |> Map.new(fn {level, count} -> {String.to_existing_atom(level), count} end)
  catch
    _, _ -> %{}
  end

  @doc """
  Writes anything pending, synchronously, and returns once it is durable.

  A `call`, so it also drains the append casts queued ahead of it -- which is
  what makes "log a line, then read it back" deterministic in a test rather
  than a race against the flush timer.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  catch
    :exit, _ -> :ok
  end

  @doc "Deletes everything. The operator's own button, on the Logs page."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  @doc "How many entries are kept before the oldest are dropped."
  @spec retention() :: pos_integer()
  def retention do
    GenServer.call(__MODULE__, :retention)
  catch
    :exit, _ -> @default_retention
  end

  @doc "The bounds a retention setting is held to, for the form to enforce."
  @spec retention_range() :: Range.t()
  def retention_range, do: @retention_range

  @doc "The setting key, so Settings and Config agree on one spelling."
  @spec retention_setting() :: String.t()
  def retention_setting, do: @retention_setting

  @doc """
  Stores a new retention and trims to it immediately.

  Kept in this process's state rather than read per flush: reading it from the
  settings table on the logging path is precisely the query that would feed
  the loop this module exists to avoid.
  """
  @spec put_retention(String.t() | integer()) :: :ok | {:error, :invalid}
  def put_retention(value) do
    case parse_retention(to_string(value)) do
      nil ->
        {:error, :invalid}

      entries ->
        Fanfarr.Settings.put_setting!(@retention_setting, Integer.to_string(entries))
        GenServer.call(__MODULE__, {:retention, entries})
    end
  catch
    :exit, _ -> :ok
  end

  # --- server -----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    schedule_flush()

    {:ok, %{pending: [], retention: configured_retention()}}
  end

  @impl true
  def handle_cast({:append, entry}, state) do
    {:noreply, %{state | pending: [entry | state.pending] |> Enum.take(@max_pending)}}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush()
    {:noreply, flush(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, flush(state)}

  def handle_call(:retention, _from, state), do: {:reply, state.retention, state}

  def handle_call({:retention, entries}, _from, state) do
    state = %{state | retention: entries}
    trim(entries)

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    Fanfarr.Repo.delete_all(Entry, log: false)

    {:reply, :ok, %{state | pending: []}}
  end

  # A last flush on the way down, so stopping the container does not throw
  # away the second that explains why it was stopped.
  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    rows =
      state.pending
      |> Enum.reverse()
      |> Enum.map(fn entry ->
        %{
          at: entry.at,
          level: to_string(entry.level),
          message: entry.message,
          where: entry.where
        }
      end)

    Fanfarr.Repo.insert_all(Entry, rows, log: false)
    trim(state.retention)

    %{state | pending: []}
  rescue
    # A write that fails must not take the logger's own supervisor down with
    # it, and must not retry the same batch forever either.
    _ -> %{state | pending: []}
  end

  # Exact rather than a watermark off MAX(id): two indexed queries against a
  # table capped in the thousands, and no arithmetic on ids that a rolled-back
  # insert could have left a gap in.
  defp trim(retention) do
    cutoff =
      from(e in Entry, order_by: [desc: e.id], offset: ^(retention - 1), limit: 1, select: e.id)
      |> Fanfarr.Repo.one(log: false)

    if cutoff do
      from(e in Entry, where: e.id < ^cutoff) |> Fanfarr.Repo.delete_all(log: false)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_ms)

  # Read once, at boot. Everything after that arrives through put_retention/1.
  defp configured_retention do
    case Fanfarr.Config.get(@retention_setting) do
      nil -> @default_retention
      value -> parse_retention(value) || @default_retention
    end
  rescue
    _ -> @default_retention
  end

  defp parse_retention(value) do
    case Integer.parse(String.trim(value)) do
      {entries, ""} -> if entries in @retention_range, do: entries, else: nil
      _ -> nil
    end
  end

  defp to_entry(%Entry{} = row) do
    %{
      at: row.at,
      level: String.to_existing_atom(row.level),
      message: row.message,
      where: row.where
    }
  end

  defp filter_level(query, nil), do: query

  defp filter_level(query, minimum) do
    from e in query, where: e.level in ^levels_at_least(minimum)
  end

  # The level column is a string, so "at least warning" becomes the set of
  # level names that qualify rather than a comparison SQL cannot make.
  defp levels_at_least(minimum) do
    for level <- Logger.levels(),
        Logger.compare_levels(level, minimum) != :lt,
        do: to_string(level)
  end

  defp filter_query(query, needle) when is_binary(needle) do
    case String.trim(needle) do
      "" ->
        query

      trimmed ->
        like = "%#{escape_like(trimmed)}%"

        # `ESCAPE` spelled out, because SQLite's LIKE has no escape character
        # unless one is named -- without it the backslashes below match
        # literal backslashes and a search for "100%" matches everything.
        from e in query,
          where:
            fragment("? LIKE ? ESCAPE '\\'", e.message, ^like) or
              fragment("? LIKE ? ESCAPE '\\'", e.where, ^like)
    end
  end

  defp filter_query(query, _needle), do: query

  # A search for "100%" is a search for a literal percent sign, not for
  # everything.
  defp escape_like(value) do
    String.replace(value, ~w(\\ % _), fn char -> "\\" <> char end)
  end
end
