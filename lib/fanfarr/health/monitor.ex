defmodule Fanfarr.Health.Monitor do
  @moduledoc """
  Runs the health checks on a schedule and keeps the latest results, so the
  sidebar badge and the System page read from memory rather than probing Plex
  on every render.

  Results are held in the process state; `latest/0` is a call, not an ETS
  read, because the numbers are tiny and a single owner keeps "when were
  these taken" trivially consistent.
  """
  use GenServer

  require Logger

  @interval :timer.minutes(10)
  # The first run waits for the endpoint and migrations to settle.
  @initial_delay :timer.seconds(15)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last results and when they were taken, or nil before the first run."
  @spec latest() :: %{results: [Fanfarr.Health.result()], at: DateTime.t()} | nil
  def latest do
    GenServer.call(__MODULE__, :latest)
  catch
    :exit, _ -> nil
  end

  @doc "Run every check now, synchronously, and remember the outcome."
  @spec refresh() :: %{results: [Fanfarr.Health.result()], at: DateTime.t()}
  def refresh, do: GenServer.call(__MODULE__, :refresh, 60_000)

  @impl true
  def init(opts) do
    unless Keyword.get(opts, :auto, true) == false do
      Process.send_after(self(), :tick, @initial_delay)
    end

    {:ok, %{latest: nil}}
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  def handle_call(:refresh, _from, state) do
    snapshot = take()
    {:reply, snapshot, %{state | latest: snapshot}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval)
    {:noreply, %{state | latest: take()}}
  end

  defp take do
    results =
      try do
        Fanfarr.Health.run_all()
      rescue
        e ->
          Logger.warning("[fanfarr] health checks crashed: #{Exception.message(e)}")

          [
            %{
              id: :monitor,
              name: "Health checks",
              level: :error,
              message: "Crashed",
              detail: Exception.message(e)
            }
          ]
      end

    %{results: results, at: DateTime.utc_now()}
  end
end
