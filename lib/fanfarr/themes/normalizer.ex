defmodule Fanfarr.Themes.Normalizer do
  @moduledoc """
  Brings a downloaded theme to a consistent loudness.

  A library ends up with themes from three places -- Plex's own agent,
  ThemerrDB, and whatever the operator picked on YouTube -- and they arrive at
  wildly different levels, because the source is whatever the uploader
  mastered. YouTube plays everything at a normalised level, but yt-dlp fetches
  the *original* stream, not the level YouTube plays it at, so a download can
  easily be several decibels louder than the theme on the show next to it.

  Normalisation is EBU R128 loudness (`loudnorm`), two-pass:

    1. measure the file's integrated loudness, true peak and range;
    2. re-encode applying exactly the gain that measurement implies.

  One pass would also work but adjusts dynamically as it goes, which pumps on
  material with a quiet intro -- exactly what an opening theme usually has.

  The target defaults to **-14 LUFS**, which is where the streaming services
  sit and therefore roughly where a YouTube-sourced theme is expected to land.
  It is a setting, because the right number is whatever matches the themes
  already in the library, and that can be measured rather than assumed: see
  `measure/1` and the loudness tool on the System page.
  """

  require Logger

  @binary "ffmpeg"

  # Streaming-standard loudness. TP is -1.5 rather than -1.0 to leave headroom
  # for the overshoot that lossy re-encoding introduces after limiting.
  @default_target -14.0
  @true_peak -1.5
  @loudness_range 11.0

  # Themes are short; a minute of audio measures in well under this.
  @timeout_ms 120_000

  @type measurement :: %{
          input_i: float(),
          input_tp: float(),
          input_lra: float(),
          input_thresh: float(),
          target_offset: float()
        }

  @doc "The configured loudness target in LUFS."
  @spec target() :: float()
  def target do
    case Fanfarr.Config.get("theme_loudness_lufs") do
      nil ->
        @default_target

      value ->
        case Float.parse(to_string(value)) do
          {parsed, _} -> parsed
          :error -> @default_target
        end
    end
  end

  @doc "Whether ffmpeg is available, and which version."
  @spec version() :: {:ok, String.t()} | {:error, :not_installed | term()}
  def version do
    case run([@binary, "-version"], 15_000) do
      {:ok, output} ->
        {:ok, output |> String.split("\n") |> List.first() |> String.trim()}

      {:error, :enoent} ->
        {:error, :not_installed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Measures a file's loudness without changing it.

  This is pass one of the two-pass normalisation, and is also what makes the
  target checkable against themes that are already in the library rather than
  guessed at.
  """
  @spec measure(Path.t()) :: {:ok, measurement()} | {:error, term()}
  def measure(path) do
    args = [
      "-hide_banner",
      "-nostats",
      "-i",
      path,
      "-af",
      "loudnorm=I=#{target()}:TP=#{@true_peak}:LRA=#{@loudness_range}:print_format=json",
      "-f",
      "null",
      "-"
    ]

    case run([@binary | args], @timeout_ms) do
      {:ok, output} -> parse_measurement(output)
      {:error, :enoent} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Normalises `path` in place, returning what it measured before and after.

  On any failure the original file is left exactly as it was: an unnormalised
  theme is worse than a normalised one, but it is far better than no theme, so
  this never turns a successful download into a failed apply.
  """
  @spec normalize(Path.t()) ::
          {:ok, %{before: float(), after: float(), target: float()}} | {:error, term()}
  def normalize(path) do
    with {:ok, measured} <- measure(path),
         {:ok, normalized_path} <- apply_gain(path, measured),
         {:ok, after_measure} <- measure(normalized_path) do
      # Only now is the original replaced, so a failure at any point above
      # leaves the downloaded file untouched.
      case File.rename(normalized_path, path) do
        :ok ->
          {:ok, %{before: measured.input_i, after: after_measure.input_i, target: target()}}

        {:error, :exdev} ->
          with :ok <- File.cp(normalized_path, path) do
            File.rm(normalized_path)
            {:ok, %{before: measured.input_i, after: after_measure.input_i, target: target()}}
          end

        {:error, reason} ->
          File.rm(normalized_path)
          {:error, reason}
      end
    end
  end

  defp apply_gain(path, m) do
    out = Path.join(Path.dirname(path), "normalized-#{:erlang.unique_integer([:positive])}.mp3")

    filter =
      "loudnorm=I=#{target()}:TP=#{@true_peak}:LRA=#{@loudness_range}" <>
        ":measured_I=#{m.input_i}:measured_TP=#{m.input_tp}" <>
        ":measured_LRA=#{m.input_lra}:measured_thresh=#{m.input_thresh}" <>
        ":offset=#{m.target_offset}:linear=true:print_format=summary"

    args = [
      "-hide_banner",
      "-nostats",
      "-y",
      "-i",
      path,
      "-af",
      filter,
      # loudnorm resamples to 192kHz internally; left alone that would be
      # baked into the output for no benefit at all in an mp3.
      "-ar",
      "48000",
      "-c:a",
      "libmp3lame",
      "-b:a",
      "192k",
      out
    ]

    case run([@binary | args], @timeout_ms) do
      {:ok, _output} ->
        if File.regular?(out), do: {:ok, out}, else: {:error, :no_output}

      {:error, reason} ->
        File.rm(out)
        {:error, reason}
    end
  end

  # ffmpeg prints the measurement as a JSON object at the end of stderr, after
  # everything else it has to say.
  defp parse_measurement(output) do
    with [_ | _] = candidates <- Regex.scan(~r/\{[^{}]*"input_i"[^{}]*\}/s, output),
         {:ok, json} <- Jason.decode(candidates |> List.last() |> List.first()) do
      {:ok,
       %{
         input_i: to_float(json["input_i"]),
         input_tp: to_float(json["input_tp"]),
         input_lra: to_float(json["input_lra"]),
         input_thresh: to_float(json["input_thresh"]),
         target_offset: to_float(json["target_offset"])
       }}
    else
      _ -> {:error, :unparseable_measurement}
    end
  end

  # ffmpeg reports "-inf" for silence, which is not a number JSON or Elixir
  # will parse, and is worth distinguishing from a failure to read the file.
  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> -70.0
    end
  end

  defp to_float(_), do: -70.0

  defp run([cmd | args], timeout) do
    task =
      Task.async(fn ->
        try do
          # loudnorm writes its report to stderr.
          System.cmd(cmd, args, stderr_to_stdout: true)
        rescue
          e in ErlangError -> {:spawn_failed, e.original}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:spawn_failed, reason}} -> {:error, reason}
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit, code, String.slice(output, 0, 400)}}
      nil -> {:error, :timeout}
    end
  end
end
