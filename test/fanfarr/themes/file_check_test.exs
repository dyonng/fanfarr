defmodule Fanfarr.Themes.FileCheckTest do
  @moduledoc "What is on disk, as opposed to what the history says was written."
  use ExUnit.Case, async: true

  alias Fanfarr.Themes.FileCheck

  @moduletag :requires_ffmpeg

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-filecheck-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "nothing written yet is its own answer" do
    assert {:error, :no_file} = FileCheck.inspect_file(nil)
    assert {:error, :no_file} = FileCheck.inspect_file("")
  end

  test "a missing file is reported, not crashed on", %{dir: dir} do
    assert {:error, {:missing, :enoent}} = FileCheck.inspect_file(Path.join(dir, "nope.mp3"))
  end

  test "a zero-byte file is called out before ffprobe is even asked", %{dir: dir} do
    path = Path.join(dir, "theme.mp3")
    File.write!(path, "")

    assert {:error, {:empty, 0}} = FileCheck.inspect_file(path)
  end

  test "bytes that are not audio read as undecodable, with their size", %{dir: dir} do
    # The case worth catching: Plex can index this and cannot play it.
    path = Path.join(dir, "theme.mp3")
    File.write!(path, String.duplicate("not audio", 200))

    assert {:error, {:unreadable, bytes}} = FileCheck.inspect_file(path)
    assert bytes == 1800
  end

  test "real audio comes back described", %{dir: dir} do
    path = Path.join(dir, "theme.mp3")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=1 -y #{path}),
        stderr_to_stdout: true
      )

    assert {:ok, info} = FileCheck.inspect_file(path)
    assert info.bytes > 0
    assert info.codec == "mp3"
    assert info.duration >= 0.9
    assert info.sample_rate > 0
  end
end
