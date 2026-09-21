defmodule Fanfarr.Library.DiskSpaceTest do
  @moduledoc """
  Free space off the filesystem holding a path, as the root-folder check reads
  it.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Library.DiskSpace

  test "reports the free space of the filesystem holding a real path" do
    free = DiskSpace.free_bytes(System.tmp_dir!())

    assert is_integer(free)
    assert free > 0
  end

  test "a path that is not there is unknown, not zero" do
    # A mount that is gone must not read as a full disk. nil is "no answer",
    # and the settings page then says nothing rather than "0 B free".
    assert DiskSpace.free_bytes("/nonexistent-fanfarr-mount") == nil
  end

  test "a path with spaces in it still resolves" do
    # The mount points these read are named things like
    # "/media/thiccer-than-your-average", and df quotes nothing without -P.
    dir = Path.join(System.tmp_dir!(), "fanfarr disk space #{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    free = DiskSpace.free_bytes(dir)

    assert is_integer(free)
    assert free > 0
  end
end
