defmodule Fanfarr.Themes.Downloader.YtDlp do
  @moduledoc """
  The real downloader, shelling out to yt-dlp.

  ## Safety

  yt-dlp is invoked through `System.cmd/3` with an argument list, never a
  shell string, so a URL can never become a command. The URL is additionally
  checked against a scheme and host allowlist before it is passed anywhere:
  yt-dlp happily accepts local file paths and other protocols, and the URLs
  arriving here come from a third-party database.

  ## Limits

  A theme is a short piece of music. The duration and size ceilings exist
  because the alternative to rejecting a ten-hour upload is downloading it
  onto someone's media drive.
  """
  @behaviour Fanfarr.Themes.Downloader

  require Logger

  @binary "yt-dlp"

  # A theme that runs longer than this is not a theme. ThemerrDB entries are
  # typically 60-120s; the ceiling is generous enough for a long main title.
  @max_duration_seconds 900
  @max_bytes 40 * 1024 * 1024
  @timeout_ms 180_000

  @allowed_schemes ~w(http https)
  @allowed_hosts ~w(
    youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be
  )

  @impl true
  def version do
    case run([@binary, "--version"], 15_000) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, :enoent} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download(url, dir) do
    with :ok <- validate_url(url),
         :ok <- ensure_dir(dir) do
      # A private subdirectory means the glob afterwards cannot pick up an
      # unrelated file, and cleanup is a single rm_rf.
      work = Path.join(dir, "ytdlp-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(work)

      try do
        do_download(url, work, dir)
      after
        File.rm_rf(work)
      end
    end
  end

  defp do_download(url, work, dir) do
    args = [
      "--no-playlist",
      "--no-progress",
      "--no-warnings",
      # Reject before downloading rather than after.
      "--match-filter",
      "duration < #{@max_duration_seconds}",
      "--max-filesize",
      "#{@max_bytes}",
      "--extract-audio",
      "--audio-format",
      "mp3",
      "--audio-quality",
      "0",
      "--restrict-filenames",
      "--output",
      Path.join(work, "theme.%(ext)s"),
      "--print-to-file",
      "%(duration)s",
      Path.join(work, "duration.txt"),
      "--no-simulate",
      url
    ]

    case run([@binary | args], @timeout_ms) do
      {:ok, output} -> collect(work, dir, output)
      {:error, :enoent} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect(work, dir, output) do
    case Path.wildcard(Path.join(work, "theme.*")) |> Enum.reject(&(&1 =~ ~r/\.txt$/)) do
      [] ->
        # yt-dlp exits 0 when a match-filter rejects the video, so "success
        # with no file" is the normal shape of "too long", not an anomaly.
        {:error, classify_empty(output)}

      [file | _] ->
        %{size: bytes} = File.stat!(file)
        final = Path.join(dir, Path.basename(file))

        case Fanfarr.Themes.Writer.place(file, final) do
          :ok ->
            {:ok,
             %{
               path: final,
               bytes: bytes,
               codec: codec_of(final),
               duration: read_duration(work)
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp classify_empty(output) do
    cond do
      output =~ "does not pass filter" -> :too_long
      output =~ "File is larger than max-filesize" -> :too_large
      output =~ ~r/Video unavailable|Private video|removed/i -> :unavailable
      true -> {:exit, 0, String.slice(output, 0, 500)}
    end
  end

  defp read_duration(work) do
    with {:ok, raw} <- File.read(Path.join(work, "duration.txt")),
         {seconds, _} <- raw |> String.trim() |> Float.parse() do
      seconds
    else
      _ -> nil
    end
  end

  # The extension is what Plex and the filesystem go by; ffprobe would be more
  # authoritative but is not worth a second process for a file we just asked
  # yt-dlp to transcode.
  defp codec_of(path) do
    case Path.extname(path) do
      "." <> ext -> String.downcase(ext)
      _ -> nil
    end
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in @allowed_schemes -> {:error, :unsupported_url}
      is_nil(uri.host) -> {:error, :unsupported_url}
      String.downcase(uri.host) not in @allowed_hosts -> {:error, :unsupported_url}
      true -> :ok
    end
  end

  defp validate_url(_), do: {:error, :unsupported_url}

  defp ensure_dir(dir) do
    case File.stat(dir) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run([cmd | args], timeout) do
    task =
      Task.async(fn ->
        try do
          System.cmd(cmd, args, stderr_to_stdout: true)
        rescue
          # A missing binary raises rather than returning; tagged so it cannot
          # be confused with a {output, exit_code} pair.
          e in ErlangError -> {:spawn_failed, e.original}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:spawn_failed, reason}} -> {:error, reason}
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit, code, String.slice(output, 0, 500)}}
      nil -> {:error, :timeout}
    end
  end
end
