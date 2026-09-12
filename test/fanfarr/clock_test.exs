defmodule Fanfarr.ClockTest do
  @moduledoc """
  The zone conversion, against the real C library rather than a stub.

  A stubbed zone database would only prove this module can read a stub. What is
  under test is that `TZ` from the compose file reaches the BEAM at all and
  that DST is handled, and only libc can answer that.

  The zone cases run in a separate VM because **the BEAM reads `TZ` once, at
  start**: measured, neither `System.put_env/2` nor `:os.putenv/2` moves it
  afterwards. That is invisible in production -- Docker sets the variable
  before the VM exists -- but it does mean changing `TZ` on a running
  appliance needs a container restart, and it means a test cannot set the zone
  for itself.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Clock

  # A fresh VM with TZ set, loading the compiled module rather than a copy of
  # its logic. Clock depends on nothing outside the standard library, so the
  # application does not need to boot.
  defp in_zone(zone, expression) do
    {output, 0} =
      System.cmd(
        "elixir",
        [
          "-pa",
          Path.join([Mix.Project.build_path(), "lib", "fanfarr", "ebin"]),
          "-e",
          expression
        ],
        env: [{"TZ", zone}],
        stderr_to_stdout: true
      )

    String.trim(output)
  end

  defp at(iso), do: iso |> DateTime.from_iso8601() |> elem(1)

  describe "the server's zone" do
    test "a UTC instant reads as the local wall clock" do
      assert in_zone(
               "America/Toronto",
               ~s|IO.puts Fanfarr.Clock.datetime(~U[2026-09-12 15:34:07Z])|
             ) == "12 Sep 2026, 11:34"
    end

    test "daylight saving is applied, because libc applies it" do
      # The reason this goes through :calendar rather than a stored offset:
      # Toronto is UTC-4 in September and UTC-5 in January, so a fixed number
      # would be wrong for half of every year.
      assert in_zone(
               "America/Toronto",
               ~s|IO.puts Fanfarr.Clock.offset(~U[2026-09-12 15:34:07Z])|
             ) == "UTC-4"

      assert in_zone(
               "America/Toronto",
               ~s|IO.puts Fanfarr.Clock.offset(~U[2026-01-15 15:34:07Z])|
             ) == "UTC-5"

      assert in_zone(
               "America/Toronto",
               ~s|IO.puts Fanfarr.Clock.precise(~U[2026-01-15 15:34:07Z])|
             ) == "15 Jan 2026, 10:34:07"
    end

    test "a zone ahead of UTC, and one that is not a whole hour off" do
      assert in_zone("Asia/Tokyo", ~s|IO.puts Fanfarr.Clock.offset(~U[2026-09-12 15:34:07Z])|) ==
               "UTC+9"

      assert in_zone("Asia/Kolkata", ~s|IO.puts Fanfarr.Clock.offset(~U[2026-09-12 15:34:07Z])|) ==
               "UTC+5:30"
    end

    test "an unset TZ stays UTC rather than guessing" do
      assert in_zone("UTC", ~s|IO.puts Fanfarr.Clock.zone()|) == "UTC"
      assert in_zone("UTC", ~s|IO.puts Fanfarr.Clock.offset(~U[2026-09-12 15:34:07Z])|) == "UTC"
    end

    test "a TZ the image cannot resolve is reported, not silently used" do
      # libc answers an unresolvable zone with UTC and says nothing, which is
      # a four-hour error in every timestamp with no symptom at all. This is
      # the shape of a slim image with no tzdata installed.
      assert in_zone("Mars/Olympus_Mons", ~s|Fanfarr.Clock.log_zone()|) =~
               "timezone database is missing"
    end
  end

  describe "ago/2" do
    test "recent work is read as how long ago" do
      now = at("2026-09-12T15:34:07Z")

      assert Clock.ago(now, now) == "just now"
      assert Clock.ago(DateTime.add(now, -40, :second), now) == "just now"
      assert Clock.ago(DateTime.add(now, -60, :second), now) == "1 minute ago"
      assert Clock.ago(DateTime.add(now, -20 * 60, :second), now) == "20 minutes ago"
      assert Clock.ago(DateTime.add(now, -3 * 3600, :second), now) == "3 hours ago"
      assert Clock.ago(DateTime.add(now, -2 * 86_400, :second), now) == "2 days ago"
    end

    test "past a week it becomes a date, because days stop being countable" do
      now = at("2026-09-12T15:34:07Z")
      old = DateTime.add(now, -9 * 86_400, :second)

      refute Clock.ago(old, now) =~ "ago"
      assert Clock.ago(old, now) == Clock.datetime(old)
    end

    test "a timestamp in the future is shown rather than counted" do
      # Clock skew between Plex and the appliance puts added_at ahead of now
      # often enough to matter, and "-3 minutes ago" is nonsense.
      now = at("2026-09-12T15:34:07Z")
      assert Clock.ago(DateTime.add(now, 300, :second), now) =~ "2026"
    end
  end
end
