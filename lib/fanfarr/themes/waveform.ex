defmodule Fanfarr.Themes.Waveform do
  @moduledoc """
  Reduces an audio file to a few hundred peak amplitudes, for drawing.

  ## Why the server does this

  The browser could decode the audio itself with `AudioContext.decodeAudioData`
  and save a round trip. It would also be decoding whatever container YouTube
  happened to serve, and Safari's Opus support is not something to bet the
  trim editor on. One ffmpeg call here produces a few kilobytes of JSON that
  every browser can draw, and it is computed once per source rather than once
  per page load.

  ## What the numbers are

  The audio is decoded to mono 8 kHz signed 16-bit PCM -- a rate chosen to make
  the decode cheap, since nothing here is listened to -- and each output bucket
  is the loudest absolute sample within it, scaled to 0..1. Peak rather than
  RMS because the question a trim editor answers is "where does the music
  start and stop", and peaks show an entrance a decibel earlier than an
  average does.
  """

  @binary "ffmpeg"
  @timeout_ms 60_000

  # Enough to see a bar line on a phone-width canvas, few enough to stay a
  # small JSON body. At 390px this is roughly three samples per pixel.
  @buckets 1000
  @rate 8000

  @doc """
  Writes the peaks for `source` to `target` as JSON, returning the count.

  The JSON is an object rather than a bare array so a duration can ride along:
  the editor needs to map a pixel to a time before any audio has loaded, and
  asking the browser to wait for metadata to draw anything is a flash of empty
  canvas for no reason.
  """
  @spec write(Path.t(), Path.t()) :: {:ok, %{peaks: non_neg_integer()}} | {:error, term()}
  def write(source, target) do
    with {:ok, pcm} <- decode(source) do
      peaks = peaks(pcm, @buckets)

      body =
        Jason.encode!(%{
          "peaks" => peaks,
          "duration_ms" => duration_ms(byte_size(pcm))
        })

      case File.write(target, body) do
        :ok -> {:ok, %{peaks: length(peaks)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # To stdout, so nothing has to be cleaned up if this fails part way.
  defp decode(source) do
    args = [
      "-hide_banner",
      "-nostats",
      "-loglevel",
      "error",
      "-i",
      source,
      "-ac",
      "1",
      "-ar",
      "#{@rate}",
      "-f",
      "s16le",
      "-"
    ]

    task =
      Task.async(fn ->
        try do
          # Not stderr_to_stdout: this reads the PCM off stdout, and mixing
          # ffmpeg's chatter into it would corrupt the samples.
          System.cmd(@binary, args, stderr_to_stdout: false)
        rescue
          e in ErlangError -> {:spawn_failed, e.original}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:spawn_failed, reason}} -> {:error, reason}
      {:ok, {pcm, 0}} when byte_size(pcm) > 0 -> {:ok, pcm}
      {:ok, {_pcm, 0}} -> {:error, :no_audio}
      {:ok, {_out, code}} -> {:error, {:exit, code}}
      nil -> {:error, :timeout}
    end
  end

  @doc """
  The loudest absolute sample in each of `buckets` equal slices of `pcm`.

  Public for the test, which is the only honest way to check this: a waveform
  is judged by eye, and an eye cannot tell a correct one from a plausible one.
  """
  @spec peaks(binary(), pos_integer()) :: [float()]
  def peaks(pcm, buckets) do
    samples = div(byte_size(pcm), 2)

    if samples == 0 do
      []
    else
      per_bucket = max(div(samples, buckets), 1)

      pcm
      |> chunk(per_bucket * 2)
      |> Enum.map(&bucket_peak/1)
      |> Enum.take(buckets)
    end
  end

  defp chunk(binary, size) when size > 0 do
    Stream.unfold(binary, fn
      <<>> -> nil
      rest when byte_size(rest) <= size -> {rest, <<>>}
      <<head::binary-size(size), rest::binary>> -> {head, rest}
    end)
  end

  # 32767 rather than 32768: the negative end of a 16-bit range reaches one
  # further than the positive, and dividing by the larger keeps every value
  # inside 0..1 without a clamp.
  defp bucket_peak(chunk) do
    chunk
    |> loudest(0)
    |> then(&Float.round(&1 / 32_767, 4))
    |> min(1.0)
  end

  defp loudest(<<sample::little-signed-16, rest::binary>>, acc),
    do: loudest(rest, max(acc, abs(sample)))

  defp loudest(_rest, acc), do: acc

  defp duration_ms(bytes), do: round(div(bytes, 2) / @rate * 1000)
end
