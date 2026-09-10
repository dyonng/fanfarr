defmodule Fanfarr.Themes.Cutter do
  @moduledoc """
  Cuts a theme down to a chosen range, with fades at both ends.

  ## Where this sits, and why it is not last

  The pipeline is download -> **cut** -> normalise -> place, and that order is
  the whole reason this is a separate step rather than a flag on the writer.
  `Fanfarr.Themes.Normalizer` is two-pass EBU R128: it measures the file's
  integrated loudness and applies exactly the gain that measurement implies.
  Cut afterwards and the measurement was taken over audio that no longer
  ships -- trim to a quiet intro and the result is quiet, trim to the chorus
  and it is hot, and the library stops being level-matched, which is the one
  thing normalisation exists to guarantee.

  ## Fades are not decoration

  Plex loops themes. A hard cut at either end clicks, and on a loop that click
  is heard every time round. The fades default to on (see `MediaItem`) and are
  applied here, in the same pass as the cut, so there is one re-encode rather
  than two.

  ## Why the cut is a filter and not -ss/-to

  It was `-ss`/`-to` first, and that silences the output whenever a fade is
  asked for. Those options cut the stream, but the frames reaching the filter
  graph still carry their original timestamps -- so on a selection from 10s to
  20s, `afade=t=out:st=8` sees every frame as past 10s, which is past the end
  of the fade, and takes the whole thing to nothing. The duration is right,
  the file is silent, and nothing says so until someone plays it.

  `atrim` then `asetpts=PTS-STARTPTS` does the cut *inside* the graph and
  rebases the timeline to zero, so the fades that follow are expressed against
  the audio that actually ships. One graph, one pass, and no ambiguity about
  what a time means. It also cuts at the sample rather than the nearest
  keyframe, which is what "starts on the downbeat" requires.

  `afade` is expressed in seconds because ffmpeg's filter syntax has no
  millisecond form -- the values arrive as milliseconds, and are divided here
  rather than anywhere a rounding choice could drift between callers.
  """

  require Logger

  @binary "ffmpeg"
  @timeout_ms 120_000

  @type range :: %{
          start_ms: non_neg_integer() | nil,
          end_ms: non_neg_integer() | nil,
          fade_in_ms: non_neg_integer(),
          fade_out_ms: non_neg_integer()
        }

  @doc """
  Whether a range would change the audio at all.

  A range of "the whole thing, no fades" is not a cut, and running one would
  cost a re-encode -- a generation of lossy loss -- to produce the same audio.
  """
  @spec trims?(range() | nil) :: boolean()
  def trims?(nil), do: false

  def trims?(%{} = range) do
    positive(range[:start_ms]) or positive(range[:end_ms]) or
      positive(range[:fade_in_ms]) or positive(range[:fade_out_ms])
  end

  defp positive(value), do: is_integer(value) and value > 0

  @doc """
  Cuts `path` in place to `range`, returning the resulting duration in ms.

  In place, like `Normalizer.normalize/1`: the caller has a scratch copy and
  the rest of the pipeline goes on referring to the same path. The cut is
  written beside it and only renamed over the original once ffmpeg has
  succeeded, so a failure leaves the download intact.
  """
  @spec cut(Path.t(), range()) :: {:ok, %{duration_ms: non_neg_integer()}} | {:error, term()}
  def cut(path, range) do
    out = Path.join(Path.dirname(path), "cut-#{:erlang.unique_integer([:positive])}.mp3")

    case run([@binary | args(path, out, range)], @timeout_ms) do
      {:ok, _output} ->
        if File.regular?(out) do
          replace(path, out, range)
        else
          {:error, :no_output}
        end

      {:error, reason} ->
        File.rm(out)
        {:error, reason}
    end
  end

  defp replace(path, out, range) do
    case File.rename(out, path) do
      :ok ->
        {:ok, %{duration_ms: duration_ms(range)}}

      {:error, :exdev} ->
        with :ok <- File.cp(out, path) do
          File.rm(out)
          {:ok, %{duration_ms: duration_ms(range)}}
        end

      {:error, reason} ->
        File.rm(out)
        {:error, reason}
    end
  end

  defp args(path, out, range) do
    ["-hide_banner", "-nostats", "-y", "-i", path] ++
      filters(range) ++
      ["-c:a", "libmp3lame", "-b:a", "192k", out]
  end

  # One chain: cut, rebase to zero, then fade. The order is the fix described
  # in the moduledoc -- a fade placed before the rebase is measured against the
  # source's timeline and silences the whole output.
  defp filters(range) do
    case trim_filters(range) ++ fade_filters(range) do
      [] -> []
      chain -> ["-af", Enum.join(chain, ",")]
    end
  end

  defp trim_filters(range) do
    start = range[:start_ms] || 0
    finish = range[:end_ms]

    bounds =
      []
      |> then(fn b -> if start > 0, do: b ++ ["start=#{seconds(start)}"], else: b end)
      |> then(fn b ->
        if is_integer(finish) and finish > start, do: b ++ ["end=#{seconds(finish)}"], else: b
      end)

    case bounds do
      [] -> []
      bounds -> ["atrim=" <> Enum.join(bounds, ":"), "asetpts=PTS-STARTPTS"]
    end
  end

  # Placed against the *output's* length, which after the rebase above starts
  # at zero: the fade-out belongs at (length - fade), not at the source's out
  # point.
  defp fade_filters(range) do
    length_ms = duration_ms(range)
    fade_in = range[:fade_in_ms] || 0
    fade_out = range[:fade_out_ms] || 0

    []
    |> then(fn f ->
      if fade_in > 0, do: f ++ ["afade=t=in:st=0:d=#{seconds(fade_in)}"], else: f
    end)
    |> then(fn f ->
      cond do
        fade_out <= 0 -> f
        # Nothing to subtract from without a known length, so a fade-out is
        # skipped rather than placed at a guess.
        is_nil(length_ms) -> f
        # A fade longer than the selection would start before zero. A hard cut
        # is better than silence.
        fade_out >= length_ms -> f
        true -> f ++ ["afade=t=out:st=#{seconds(length_ms - fade_out)}:d=#{seconds(fade_out)}"]
      end
    end)
  end

  defp duration_ms(%{start_ms: start, end_ms: finish})
       when is_integer(finish) and finish > 0 do
    finish - (start || 0)
  end

  defp duration_ms(_range), do: nil

  # ffmpeg takes seconds; the rest of the app speaks milliseconds. Three
  # decimals is exactly a millisecond, so nothing is lost in the conversion.
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 3)

  defp run([cmd | args], timeout) do
    task =
      Task.async(fn ->
        try do
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
