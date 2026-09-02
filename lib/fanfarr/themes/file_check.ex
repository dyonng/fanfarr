defmodule Fanfarr.Themes.FileCheck do
  @moduledoc """
  What is actually on disk, as ffprobe sees it.

  Distinct from the history row, which records what the download reported at
  the time. A file can be written correctly and then be wrong later -- a
  truncated copy, a rename that lost bytes, an mp3 that is not one -- and the
  history would still say it succeeded.

  This exists because Plex listed a theme it then refused to serve, and
  answered 500 when asked to select that one specifically. Both are consistent
  with a file Plex can index but not decode, and neither is worth guessing at
  when ffprobe will say.
  """
  @binary "ffprobe"
  @timeout_ms 15_000

  @type info :: %{
          bytes: non_neg_integer(),
          format: String.t() | nil,
          codec: String.t() | nil,
          duration: float() | nil,
          bit_rate: integer() | nil,
          sample_rate: integer() | nil,
          channels: integer() | nil
        }

  @doc """
  Probes a written theme.

  `{:error, {:unreadable, size}}` is the interesting one: the file exists and
  ffprobe cannot make sense of it, which is what a player would also find.
  """
  @spec inspect_file(Path.t() | nil) :: {:ok, info()} | {:error, term()}
  def inspect_file(path) when path in [nil, ""], do: {:error, :no_file}

  def inspect_file(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} ->
        {:error, {:empty, 0}}

      {:ok, %{size: size}} ->
        case probe(path) do
          {:ok, info} -> {:ok, Map.put(info, :bytes, size)}
          {:error, _reason} -> {:error, {:unreadable, size}}
        end

      {:error, reason} ->
        {:error, {:missing, reason}}
    end
  end

  defp probe(path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=format_name,duration,bit_rate",
      "-show_entries",
      "stream=codec_name,sample_rate,channels",
      "-of",
      "json",
      path
    ]

    with {:ok, output} <- run([@binary | args], @timeout_ms),
         {:ok, json} <- Jason.decode(output) do
      format = json["format"] || %{}
      stream = json |> Map.get("streams", []) |> List.first() || %{}

      {:ok,
       %{
         format: format["format_name"],
         duration: to_number(format["duration"]),
         bit_rate: to_integer(format["bit_rate"]),
         codec: stream["codec_name"],
         sample_rate: to_integer(stream["sample_rate"]),
         channels: stream["channels"]
       }}
    end
  end

  defp run(command, timeout) do
    task =
      Task.async(fn ->
        System.cmd(hd(command), tl(command), stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit, code, String.slice(output, 0, 300)}}
      nil -> {:error, :timeout}
    end
  rescue
    ErlangError -> {:error, :not_installed}
  end

  defp to_number(nil), do: nil

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> Float.round(number, 1)
      :error -> nil
    end
  end

  defp to_number(value) when is_number(value), do: value

  defp to_integer(nil), do: nil

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(_), do: nil
end
