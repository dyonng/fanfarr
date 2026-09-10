defmodule Fanfarr.Themes.CutterTest do
  @moduledoc """
  Cutting a theme to a range, with the fades that stop a loop clicking.

  Real ffmpeg throughout: the thing under test is what comes out of ffmpeg,
  and asserting on the arguments we built would test our own opinion of them.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Themes.Cutter

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-cut-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp tone(dir, seconds) do
    path = Path.join(dir, "theme-#{System.unique_integer([:positive])}.mp3")

    {_out, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=#{seconds} -c:a libmp3lame) ++
          [path],
        stderr_to_stdout: true
      )

    path
  end

  defp duration(path) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -show_entries format=duration -of default=nw=1:nk=1) ++ [path],
        stderr_to_stdout: true
      )

    out |> String.trim() |> String.to_float()
  end

  # Mean volume over a window, which is how a fade is checked: a fade is not
  # visible in a duration and is the whole reason this module exists.
  defp mean_db(path, from, to) do
    {out, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -nostats -ss #{from} -to #{to} -i #{path} -af volumedetect -f null -),
        stderr_to_stdout: true
      )

    [_, value] = Regex.run(~r/mean_volume:\s*(-?\d+(?:\.\d+)?) dB/, out)
    String.to_float(value)
  end

  describe "trims?/1" do
    test "a whole track with no fades is not a cut" do
      # Re-encoding to produce identical audio spends a generation of lossy
      # loss for nothing, so the pipeline has to be able to tell.
      refute Cutter.trims?(%{start_ms: nil, end_ms: nil, fade_in_ms: 0, fade_out_ms: 0})
      refute Cutter.trims?(nil)
    end

    test "any of the four makes it one" do
      base = %{start_ms: nil, end_ms: nil, fade_in_ms: 0, fade_out_ms: 0}

      assert Cutter.trims?(%{base | start_ms: 1})
      assert Cutter.trims?(%{base | end_ms: 1})
      assert Cutter.trims?(%{base | fade_in_ms: 1})
      assert Cutter.trims?(%{base | fade_out_ms: 1})
    end
  end

  test "it cuts to the range, in place", %{dir: dir} do
    path = tone(dir, 30)

    assert {:ok, %{duration_ms: 12_000}} =
             Cutter.cut(path, %{start_ms: 3_000, end_ms: 15_000, fade_in_ms: 0, fade_out_ms: 0})

    assert_in_delta duration(path), 12.0, 0.3
  end

  test "an open end runs to the end of the source", %{dir: dir} do
    path = tone(dir, 10)

    assert {:ok, _} =
             Cutter.cut(path, %{start_ms: 4_000, end_ms: nil, fade_in_ms: 0, fade_out_ms: 0})

    assert_in_delta duration(path), 6.0, 0.3
  end

  describe "fades" do
    test "the fade-out lands at the end of the output, not of the source", %{dir: dir} do
      # The subtle one. afade's start time is relative to the *output*, so a
      # fade-out has to be placed at (length - fade). Given the source's out
      # point instead it lands somewhere in the middle of a trimmed track, or
      # past the end and nowhere at all.
      path = tone(dir, 30)

      assert {:ok, _} =
               Cutter.cut(path, %{
                 start_ms: 10_000,
                 end_ms: 20_000,
                 fade_in_ms: 0,
                 fade_out_ms: 2_000
               })

      assert_in_delta duration(path), 10.0, 0.3

      # Quiet at the very end, and full level in the middle where no fade
      # belongs. Measured over the last half second: the fade is linear, so a
      # window covering all two seconds averages far closer to full level than
      # the tail actually is.
      assert mean_db(path, 9.4, 9.9) < mean_db(path, 4, 6) - 6
    end

    test "a fade-in makes the opening quieter than the body", %{dir: dir} do
      path = tone(dir, 20)

      assert {:ok, _} =
               Cutter.cut(path, %{
                 start_ms: 0,
                 end_ms: 10_000,
                 fade_in_ms: 2_000,
                 fade_out_ms: 0
               })

      assert mean_db(path, 0, 0.5) < mean_db(path, 4, 6) - 6
    end

    test "a fade longer than the track is skipped rather than silencing it", %{dir: dir} do
      # Asking for a two-second fade-out of a one-second selection would put
      # afade's start time before zero. Better a hard cut than silence.
      path = tone(dir, 20)

      assert {:ok, _} =
               Cutter.cut(path, %{
                 start_ms: 0,
                 end_ms: 1_000,
                 fade_in_ms: 0,
                 fade_out_ms: 5_000
               })

      assert mean_db(path, 0, 0.9) > -30
    end
  end

  test "a failure leaves the original alone", %{dir: dir} do
    path = Path.join(dir, "not-audio.mp3")
    File.write!(path, "this is not audio")

    assert {:error, _reason} =
             Cutter.cut(path, %{start_ms: 0, end_ms: 1_000, fade_in_ms: 0, fade_out_ms: 0})

    assert File.read!(path) == "this is not audio"
  end
end
