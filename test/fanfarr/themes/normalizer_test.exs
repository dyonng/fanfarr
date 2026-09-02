defmodule Fanfarr.Themes.NormalizerTest do
  @moduledoc """
  Real ffmpeg against real audio. Mocking this would prove only that the code
  calls a function; the question is whether files at wildly different levels
  come out at the same one.
  """
  use Fanfarr.DataCase, async: false

  @moduletag :requires_ffmpeg

  alias Fanfarr.Themes.Normalizer

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-loud-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # A tone at a chosen level, standing in for a theme mastered loud or quiet.
  defp tone(dir, name, db) do
    path = Path.join(dir, "#{name}.mp3")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=6",
          "-af",
          "volume=#{db}dB",
          "-c:a",
          "libmp3lame",
          "-b:a",
          "192k",
          path
        ],
        stderr_to_stdout: true
      )

    path
  end

  test "brings files at very different levels to the same loudness", %{dir: dir} do
    loud = tone(dir, "loud", 0)
    quiet = tone(dir, "quiet", -25)

    {:ok, loud_before} = Normalizer.measure(loud)
    {:ok, quiet_before} = Normalizer.measure(quiet)

    # The premise: these really are far apart to begin with.
    assert abs(loud_before.input_i - quiet_before.input_i) > 15

    assert {:ok, loud_result} = Normalizer.normalize(loud)
    assert {:ok, quiet_result} = Normalizer.normalize(quiet)

    target = Normalizer.target()

    for result <- [loud_result, quiet_result] do
      assert_in_delta result.after, target, 1.0
    end

    # And to each other, which is the point: one show must not blast after
    # the one before it.
    assert_in_delta loud_result.after, quiet_result.after, 0.5
  end

  test "normalising rewrites the file in place", %{dir: dir} do
    path = tone(dir, "in-place", -20)
    before_size = File.stat!(path).size

    assert {:ok, _} = Normalizer.normalize(path)

    assert File.regular?(path)
    assert File.stat!(path).size != before_size, "the file should have been re-encoded"
    assert File.ls!(dir) == ["in-place.mp3"], "no temporary files left behind"
  end

  test "measure reports the level without changing anything", %{dir: dir} do
    path = tone(dir, "measured", -30)
    digest = :crypto.hash(:sha, File.read!(path))

    assert {:ok, measurement} = Normalizer.measure(path)
    assert is_float(measurement.input_i)
    assert measurement.input_i < -20

    assert :crypto.hash(:sha, File.read!(path)) == digest
  end

  test "the target is configurable, and used", %{dir: dir} do
    Fanfarr.Settings.put_setting!("theme_loudness_lufs", "-20")
    assert Normalizer.target() == -20.0

    path = tone(dir, "custom", 0)
    assert {:ok, result} = Normalizer.normalize(path)
    assert_in_delta result.after, -20.0, 1.0
  end

  test "a file ffmpeg cannot read is an error, and leaves the file alone", %{dir: dir} do
    path = Path.join(dir, "not-audio.mp3")
    File.write!(path, "this is not audio")

    assert {:error, _reason} = Normalizer.normalize(path)
    assert File.read!(path) == "this is not audio"
  end

  test "version reports ffmpeg" do
    assert {:ok, version} = Normalizer.version()
    assert version =~ "ffmpeg version"
  end
end
