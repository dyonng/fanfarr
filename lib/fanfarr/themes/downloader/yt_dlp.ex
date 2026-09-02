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

  @impl true
  def version do
    case run([@binary, "--version"], 15_000) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, :enoent} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  @search_timeout_ms 30_000

  @impl true
  def search(query, limit) when is_binary(query) and is_integer(limit) and limit > 0 do
    query = String.trim(query)

    if query == "" do
      {:ok, []}
    else
      # ytsearchN: is yt-dlp's own search pseudo-URL; no API key involved.
      # --flat-playlist returns the listing without visiting each video, which
      # is the difference between one request and eleven.
      args = [
        "--dump-json",
        "--flat-playlist",
        "--no-warnings",
        "--no-playlist",
        "ytsearch#{min(limit, 25)}:#{query}"
      ]

      case run([@binary | args], @search_timeout_ms) do
        {:ok, output} -> {:ok, parse_search(output)}
        {:error, :enoent} -> {:error, :not_installed}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # One JSON object per line. A line that fails to parse is dropped rather than
  # failing the whole search: yt-dlp occasionally prints a warning on stdout.
  @doc false
  def parse_search(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => id} = v} when is_binary(id) ->
          [
            %{
              id: id,
              url: v["url"] || "https://www.youtube.com/watch?v=#{id}",
              title: v["title"] || id,
              channel: v["channel"] || v["uploader"],
              duration: number(v["duration"]),
              thumbnail: best_thumbnail(v),
              view_count: number(v["view_count"])
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: nil

  # Flat listings carry a thumbnails array in some versions and a single
  # thumbnail string in others; take whichever is there.
  defp best_thumbnail(%{"thumbnails" => [_ | _] = thumbs}) do
    thumbs |> List.last() |> Map.get("url")
  end

  defp best_thumbnail(%{"thumbnail" => url}) when is_binary(url), do: url
  defp best_thumbnail(_), do: nil

  @impl true
  def probe(url) do
    with :ok <- validate_url(url) do
      # --simulate does everything except write the file, so a success here is
      # a real answer about this video rather than a guess from its metadata.
      args = ["--simulate", "--dump-json", "--no-playlist", "--no-warnings", url]

      case run([@binary | args], @search_timeout_ms) do
        {:ok, output} ->
          case parse_search(output) do
            [%{title: title} = hit | _] ->
              {:ok, %{title: title, duration: hit.duration, uploader: hit.channel}}

            [] ->
              {:error, :unavailable}
          end

        {:error, :enoent} ->
          {:error, :not_installed}

        {:error, {:exit, _code, output}} ->
          {:error, classify_failure(output)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # yt-dlp reports why it could not fetch a video on stderr; the distinctions
  # that matter to an operator are "gone", "needs an account" and "blocked".
  #
  # The wordings are yt-dlp's own and it has several for the same condition --
  # "Video unavailable" and "This video is not available" are both it saying
  # the video is gone, and matching only the first left the second as a raw
  # exit code that the queue then retried five times.
  @gone ~r/
    Private\svideo
    |video\sis\snot\savailable
    |Video\sunavailable
    |has\sbeen\sremoved
    |does\snot\sexist
    |account\sassociated\swith\sthis\svideo\shas\sbeen\sterminated
    |removed\sby\sthe\suploader
    |unavailable\sin\syour\slocation
  /xi

  @doc false
  # Public only so the suite can pin the exact wordings a live yt-dlp emits.
  # A bare /age/ matched inside ordinary words, so anything mentioning a
  # "message" or a "package" read as age-gated.
  @restricted ~r/age[-\s]?restrict|confirm\syour\sage|Sign\sin\sto\sconfirm/i

  # yt-dlp phrases this several ways, and none of them contain the literal
  # "not available in your country" the first pattern demanded.
  @blocked ~r/available\sin\syour\s(country|location|region)|geo[-\s]?block|blocked\sit\son\scopyright/i

  def classify_failure(output) do
    cond do
      output =~ @gone -> :unavailable
      output =~ @restricted -> :age_restricted
      output =~ @blocked -> :geo_blocked
      true -> {:exit, 1, String.slice(output, 0, 300)}
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
      # Same classification the probe gets. Without it a download failure came
      # back as a raw exit code carrying the whole transcript, which read as a
      # crash rather than "YouTube took this video down".
      {:error, {:exit, _code, output}} -> {:error, classify_failure(output)}
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

  defp validate_url(url) do
    if Fanfarr.Themes.Downloader.youtube_url?(url), do: :ok, else: {:error, :unsupported_url}
  end

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
