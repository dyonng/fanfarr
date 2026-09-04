defmodule Fanfarr.Log.Buffer do
  @moduledoc """
  Keeps the most recent log entries in memory so the System page can show them.

  A self-hosted box has logs, but reading them means `docker logs` and a shell,
  which is a big step up from clicking a button -- and the person who most
  needs to send them a bug report is the least likely to take it. So the last
  few hundred entries are held here and rendered in the dashboard.

  Entries are redacted as they arrive (see `Fanfarr.Diagnostics.Redactor`).
  That matters more than it sounds: in dev, Ecto logs every query with its
  parameters, and one of those parameters is the Plex token being written to
  the settings table.

  Bounded and lossy by design. This is a debugging aid, not an audit trail --
  the application log in the database is the record that must not be lost.
  """
  use GenServer

  @handler_id :fanfarr_log_buffer
  @max_entries 400

  @type entry :: %{
          at: DateTime.t(),
          level: Logger.level(),
          message: String.t(),
          where: String.t() | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts feeding this buffer from the Erlang logger."
  def attach do
    :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
  end

  def detach, do: :logger.remove_handler(@handler_id)

  @doc """
  Recent entries, newest first.

  `:level` keeps entries at or above a severity; `:limit` caps how many.
  """
  @spec entries(keyword()) :: [entry()]
  def entries(opts \\ []) do
    GenServer.call(__MODULE__, {:entries, opts})
  catch
    :exit, _ -> []
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  # --- :logger handler --------------------------------------------------------

  @doc false
  # Runs inside whichever process just logged, so it does the least work it can
  # and can never raise: an exception here would take down unrelated code whose
  # only mistake was writing a log line.
  def log(event, _config) do
    GenServer.cast(__MODULE__, {:append, to_entry(event)})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp to_entry(%{level: level, msg: msg, meta: meta}) do
    %{
      at: timestamp(meta),
      level: level,
      message: text(msg),
      where: where(meta)
    }
  end

  # An event that cannot be formatted is degraded, never dropped.
  #
  # Formatting used to sit inside the caller's rescue, so anything that raised
  # here vanished without trace -- and the events most likely to raise are
  # exactly the ones worth keeping. A crash report carries raw binaries and
  # improper chardata, either of which can defeat chardata_to_string or the
  # redactor's regexes. The symptom is a console showing a 500 with no error
  # beside it, which is precisely what it must not do.
  defp text(msg) do
    msg
    |> message()
    |> printable()
    |> strip_ansi()
    |> Fanfarr.Diagnostics.Redactor.redact()
  rescue
    error -> "[entry could not be formatted: #{inspect(error.__struct__)}]"
  catch
    kind, reason -> "[entry could not be formatted: #{inspect({kind, reason})}]"
  end

  # Ecto colours its query logging for a terminal, and those escape sequences
  # survive into anywhere this text ends up -- the log console rendered them
  # as mojibake, and the bug-report bundle carried them into whatever the
  # operator pasted it into. Nothing downstream of here is a terminal, so they
  # are only ever noise.
  @ansi ~r/\e\[[0-9;]*[a-zA-Z]/
  defp strip_ansi(string), do: String.replace(string, @ansi, "")

  # The redactor runs regexes, which raise on a binary that is not valid UTF-8.
  # Log messages carrying raw bytes are not rare enough to lose.
  defp printable(string) do
    if String.valid?(string) do
      string
    else
      String.replace_invalid(string)
    end
  end

  defp message({:string, chardata}) do
    IO.chardata_to_string(chardata)
  rescue
    _ -> inspect(chardata, limit: 30, printable_limit: 2048)
  end

  defp message({:report, report}) when is_map(report) or is_list(report),
    do: inspect(report, limit: 30, printable_limit: 2048)

  defp message({format, args}) when is_list(args) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  rescue
    _ -> inspect({format, args}, limit: 20)
  end

  defp message(other), do: inspect(other, limit: 20)

  defp timestamp(%{time: microseconds}) when is_integer(microseconds) do
    DateTime.from_unix!(microseconds, :microsecond)
  end

  defp timestamp(_), do: DateTime.utc_now()

  defp where(%{mfa: {mod, fun, arity}}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp where(%{module: mod}) when not is_nil(mod), do: inspect(mod)
  defp where(_), do: nil

  # --- server -----------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{entries: []}}

  @impl true
  def handle_cast({:append, entry}, state) do
    {:noreply, %{state | entries: Enum.take([entry | state.entries], @max_entries)}}
  end

  @impl true
  def handle_call({:entries, opts}, _from, state) do
    minimum = Keyword.get(opts, :level, :debug)
    limit = Keyword.get(opts, :limit, @max_entries)

    entries =
      state.entries
      |> Enum.filter(&at_least?(&1.level, minimum))
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | entries: []}}

  defp at_least?(level, minimum) do
    Logger.compare_levels(level, minimum) != :lt
  end
end
