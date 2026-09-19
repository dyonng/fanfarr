defmodule FanfarrWeb.FormatTest do
  @moduledoc """
  The units the dashboard, the library and the item page report in.
  """
  use ExUnit.Case, async: true

  alias FanfarrWeb.Format

  test "the unit moves up at the binary boundary, not a decimal one" do
    assert Format.bytes(0) == "0 B"
    assert Format.bytes(1023) == "1023 B"

    assert Format.bytes(1024) == "1 KB"
    assert Format.bytes(1_048_575) == "1023 KB"

    assert Format.bytes(1_048_576) == "1.0 MB"
    assert Format.bytes(1_073_741_823) == "1024.0 MB"

    # The cap the trim cache is configured with, which is the number this is
    # most likely to be read next to.
    assert Format.bytes(1_073_741_824) == "1.0 GB"
    assert Format.bytes(2 * 1024 * 1024 * 1024) == "2.0 GB"
  end

  test "the fraction is kept from MB up, and dropped below it" do
    # A theme is tens or hundreds of KB; the fraction there is noise, and the
    # difference between 1.3 MB and 1.4 MB is the only digit that moves.
    assert Format.bytes(417_000) == "407 KB"
    assert Format.bytes(1_500_000) == "1.4 MB"
  end

  test "a length reads as m:ss, truncated rather than rounded" do
    assert Format.duration_ms(0) == "0:00"
    assert Format.duration_ms(9_000) == "0:09"
    assert Format.duration_ms(59_999) == "0:59"
    assert Format.duration_ms(60_000) == "1:00"
    assert Format.duration_ms(162_000) == "2:42"

    # 2:42.9 of audio is 2:42; rounding up would claim a second the file does
    # not have.
    assert Format.duration_ms(162_900) == "2:42"

    # The downloader's ceiling is 15 minutes, so there is no hours field to
    # format and this stays unambiguous.
    assert Format.duration_ms(900_000) == "15:00"
  end
end
