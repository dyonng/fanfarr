defmodule FanfarrWeb.FormatTest do
  @moduledoc """
  The units the dashboard and the item page report sizes in.
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
end
