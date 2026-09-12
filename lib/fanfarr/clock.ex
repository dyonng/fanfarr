defmodule Fanfarr.Clock do
  @moduledoc """
  Every timestamp the dashboard shows, in the appliance's own timezone.

  Fanfarr stores UTC and renders local. The zone is the container's -- `TZ` in
  the compose file, the same variable everything else in a media stack is
  configured with -- so one server answers one way and the dashboard reads the
  same on a phone, a laptop and a TV browser.

  That is a deliberate choice over asking the browser. Localising per-viewer is
  more "correct" in the abstract and was how this worked first, but it means a
  laptop that travelled disagrees with the box in the basement about when a
  sync ran, and an appliance has one clock the operator already thinks in.

  **No timezone library.** `:calendar.universal_time_to_local_time/1` goes
  through the C library, which reads `TZ` and the system zoneinfo, so the
  conversion is the same one `date` does and DST comes for free -- measured at
  UTC-4 in July and UTC-5 in January for America/Toronto. Adding `tz` or
  `tzdata` would mean a second copy of the zone rules to keep current, and
  `tzdata` in particular wants to fetch updates over the network, which an
  appliance on someone's LAN should not be doing.

  The one thing this depends on is the zoneinfo files actually being in the
  image. They are not in `debian:*-slim` by default, and libc answers a `TZ` it
  cannot resolve by silently using UTC -- so the Dockerfile installs `tzdata`
  and `describe/0` is logged at boot, where a zone that did not take shows up
  as `UTC` next to a `TZ` that says otherwise.
  """

  require Logger

  @doc """
  A UTC `DateTime` as a `NaiveDateTime` in the server's zone.

  Naive on purpose: it is a wall-clock reading for display, and the offset that
  produced it is already gone by the time anything formats it.
  """
  @spec local(DateTime.t()) :: NaiveDateTime.t()
  def local(%DateTime{} = at) do
    {date, {hour, minute, second}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    {:ok, naive} = NaiveDateTime.from_erl({date, {hour, minute, second}})
    naive
  end

  @doc "The configured zone's name, or `\"UTC\"` when `TZ` is unset."
  @spec zone() :: String.t()
  def zone do
    case System.get_env("TZ") do
      nil -> "UTC"
      "" -> "UTC"
      zone -> zone
    end
  end

  @doc """
  The offset in effect for a given instant, as `\"UTC-4\"`.

  Per-instant rather than per-zone, because half the year it is a different
  number and a row from July should say what it meant in July.
  """
  @spec offset(DateTime.t()) :: String.t()
  def offset(%DateTime{} = at) do
    minutes = div(NaiveDateTime.diff(local(at), DateTime.to_naive(at)), 60)

    cond do
      minutes == 0 -> "UTC"
      rem(minutes, 60) == 0 -> "UTC#{sign(minutes)}#{div(abs(minutes), 60)}"
      true -> "UTC#{sign(minutes)}#{div(abs(minutes), 60)}:#{pad(rem(abs(minutes), 60))}"
    end
  end

  defp sign(minutes) when minutes < 0, do: "-"
  defp sign(_), do: "+"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "A date and time, e.g. `\"12 Sep 2026, 11:34\"`."
  @spec datetime(DateTime.t()) :: String.t()
  def datetime(%DateTime{} = at), do: Calendar.strftime(local(at), "%-d %b %Y, %H:%M")

  @doc "A date, time and seconds, for the places that care about seconds."
  @spec precise(DateTime.t()) :: String.t()
  def precise(%DateTime{} = at), do: Calendar.strftime(local(at), "%-d %b %Y, %H:%M:%S")

  @doc "Wall-clock time only, e.g. `\"11:34:07\"`."
  @spec time(DateTime.t()) :: String.t()
  def time(%DateTime{} = at), do: Calendar.strftime(local(at), "%H:%M:%S")

  @doc """
  How long ago, in words, falling back to a date once "days ago" stops helping.

  A week is the cut-off because past it the question changes: "nine days ago"
  is arithmetic homework, while a date can be lined up against something else.
  """
  @spec ago(DateTime.t(), DateTime.t()) :: String.t()
  def ago(%DateTime{} = at, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(now, at)

    cond do
      seconds < 0 -> datetime(at)
      seconds < 45 -> "just now"
      seconds < 5400 -> count(round(seconds / 60), "minute")
      seconds < 86_400 -> count(round(seconds / 3600), "hour")
      seconds < 604_800 -> count(round(seconds / 86_400), "day")
      true -> datetime(at)
    end
  end

  defp count(1, unit), do: "1 #{unit} ago"
  defp count(n, unit), do: "#{n} #{unit}s ago"

  @doc """
  What the clock resolved to, for the boot log and the System page.

  Names both halves, because the failure this exists to catch is a `TZ` that
  did not resolve: the zone says America/Toronto and the offset says UTC.
  """
  @spec describe() :: String.t()
  def describe do
    now = DateTime.utc_now()
    "#{zone()} (#{offset(now)}, now #{precise(now)})"
  end

  @doc """
  Logs the zone at boot, loudly when it looks like it did not take.

  libc answers a `TZ` it cannot resolve by using UTC and saying nothing, so a
  missing zoneinfo package is otherwise a silent four-hour error in every
  timestamp on the dashboard.
  """
  @spec log_zone() :: :ok
  def log_zone do
    zone = zone()

    if zone != "UTC" and offset(DateTime.utc_now()) == "UTC" do
      Logger.warning(
        "[fanfarr] TZ is set to #{zone} but times are resolving as UTC -- the " <>
          "timezone database is missing from this image, so every timestamp on " <>
          "the dashboard will be UTC"
      )
    else
      Logger.info("[fanfarr] times are shown in #{describe()}")
    end

    :ok
  end
end
