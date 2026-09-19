defmodule Fanfarr.Themes.Pcm do
  @moduledoc """
  Decoding an audio file to mono 8 kHz PCM, for anything that measures audio
  rather than plays it.

  One definition because two things now need samples: the trim editor's
  waveform, which draws them, and `AutoCrop`, which analyses them. Both want
  the same cheap reduction of whatever container YouTube served -- a rate
  chosen to make the decode fast, since nothing here is listened to.

  Signed 16-bit little-endian, mono, so a frame is a plain binary that can be
  walked with a bitstring generator rather than parsed.
  """

  @binary "ffmpeg"
  @timeout_ms 60_000
  @rate 8000

  @doc "Samples per second. 8 kHz is plenty for envelopes and peaks."
  @spec rate() :: pos_integer()
  def rate, do: @rate

  @doc """
  `source` as raw s16le mono PCM.

  To stdout, so nothing has to be cleaned up if this fails part way.
  """
  @spec decode(Path.t()) :: {:ok, binary()} | {:error, term()}
  def decode(source) do
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
      {:ok, {_pcm, 0}} -> {:error, :empty}
      {:ok, {_out, code}} -> {:error, {:exit, code}}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end
end
