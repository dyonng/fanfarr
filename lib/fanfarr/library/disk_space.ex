defmodule Fanfarr.Library.DiskSpace do
  @moduledoc """
  Free space on the filesystem holding a path.

  Themes are small, so this is not a guard against a write failing for want of
  room. It is the other half of the root-folder health check: "accessible and
  writable" says the mount is there, and this says how much room is left on it,
  which is what an operator wants to see before a drive fills up rather than
  after.

  Nothing here raises. A path that cannot be measured -- a mount that is gone,
  a path the process cannot stat -- answers nil, and the caller records unknown
  rather than zero, because a drive reading "0 B free" would be alarming and
  wrong.
  """

  @doc """
  Free bytes on the filesystem holding `path`, or nil if it cannot be read.
  """
  @spec free_bytes(Path.t()) :: non_neg_integer() | nil
  def free_bytes(path) do
    # -P is the POSIX format, which keeps one filesystem to one line even when
    # the mount point contains spaces. The mounts this reads are named things
    # like "/media/thiccer-than-your-average", so that is not hypothetical.
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      _ -> nil
    end
  rescue
    # df missing is not a reason for the settings page to stop rendering.
    ErlangError -> nil
  end

  # A header, then a row per filesystem: filesystem, 1024-blocks, used,
  # available, capacity, mount point. The available figure is the fourth field
  # and comes before the mount point, so splitting on whitespace cannot mistake
  # it for part of a path with spaces in it.
  defp parse(output) do
    with [_header | rows] <- String.split(output, "\n", trim: true),
         row when is_binary(row) <- List.last(rows),
         [_filesystem, _blocks, _used, available | _rest] <-
           String.split(row, ~r/\s+/, trim: true),
         {kb, ""} <- Integer.parse(available) do
      kb * 1024
    else
      _ -> nil
    end
  end
end
