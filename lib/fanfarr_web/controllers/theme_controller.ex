defmodule FanfarrWeb.ThemeController do
  @moduledoc """
  Streams back the theme file Fanfarr wrote, so it can be listened to from the
  item page.

  Writing a file and reporting success is not the same as having written the
  right audio: yt-dlp can hand back the wrong video, a trailer, or silence, and
  none of that is visible in a log line saying "succeeded". Hearing it is the
  only check that actually settles it.

  Only ever serves the path recorded in the application log for that item, and
  only when it is still a regular file -- never a path from the request.

  Supports range requests, which is what lets the player seek and read a
  duration without downloading the whole file first.
  """
  use FanfarrWeb, :controller

  require Logger

  def show(conn, %{"id" => id}) do
    with {:ok, item} <- Fanfarr.Library.get_media_item(id),
         path when is_binary(path) <- item.local_theme_path,
         {:ok, %{size: size}} <- regular_file(path) do
      conn
      |> put_resp_content_type(content_type(path))
      # The file is replaced in place when a theme is re-applied and the URL
      # does not change, so it must not be cached.
      |> put_resp_header("cache-control", "no-store")
      |> serve(path, size)
    else
      _ -> send_resp(conn, 404, "no theme file for this item")
    end
  end

  @doc """
  The audio the trim editor scrubs, which is not the written theme.

  A crop has to be chosen against the *whole* source; the file next to the
  media may already be a trimmed rendering of it. `Fanfarr.Themes.EditSource`
  decides which of the cache, the written file or a fresh download can answer
  that, and this only serves the result.

  Nothing about the request names a path. The item id is looked up, the source
  is resolved from what the item already points at, and the file that comes
  back is one Fanfarr put in its own cache directory -- a request cannot ask
  for a file of its own choosing.
  """
  def edit_source(conn, %{"id" => id}) do
    with {:ok, item} <- Fanfarr.Library.get_media_item(id),
         {:ok, %{path: path}} <- Fanfarr.Themes.EditSource.resolve(item),
         {:ok, %{size: size}} <- regular_file(path) do
      conn
      |> put_resp_content_type(content_type(path))
      |> put_resp_header("cache-control", "no-store")
      |> serve(path, size)
    else
      _ -> send_resp(conn, 404, "no editable source for this item")
    end
  end

  @doc """
  The waveform peaks for that same source, as JSON.

  Computed once when the source enters the cache, so this is a file read.
  """
  def edit_peaks(conn, %{"id" => id}) do
    with {:ok, item} <- Fanfarr.Library.get_media_item(id),
         {:ok, %{peaks: peaks}} <- Fanfarr.Themes.EditSource.resolve(item),
         {:ok, body} <- File.read(peaks) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, ~s({"error":"no waveform for this item"}))
    end
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  # Range requests, because the player has a seek bar. Without them a browser
  # cannot jump to the middle of a track it has not finished downloading, and
  # cannot read the duration without pulling the whole file -- which is why
  # the control showed 0:00 / 0:00 until it had.
  defp serve(conn, path, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        case parse_range(spec, size) do
          {:ok, first, last} ->
            conn
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
            |> FanfarrWeb.SendFile.file(206, path, first, last - first + 1)

          :unsatisfiable ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "")

          :error ->
            whole(conn, path)
        end

      _ ->
        whole(conn, path)
    end
  end

  defp whole(conn, path) do
    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> FanfarrWeb.SendFile.file(200, path)
  end

  # Only the single-range forms a media element actually sends.
  defp parse_range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {length, ""} when length > 0 -> {:ok, max(size - length, 0), size - 1}
          _ -> :error
        end

      [first, ""] ->
        case Integer.parse(first) do
          {start, ""} when start < size -> {:ok, start, size - 1}
          {start, ""} when start >= size -> :unsatisfiable
          _ -> :error
        end

      [first, last] ->
        with {start, ""} <- Integer.parse(first),
             {stop, ""} <- Integer.parse(last) do
          cond do
            start >= size -> :unsatisfiable
            start > stop -> :error
            true -> {:ok, start, min(stop, size - 1)}
          end
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".opus" -> "audio/opus"
      ".ogg" -> "audio/ogg"
      ".flac" -> "audio/flac"
      _ -> "application/octet-stream"
    end
  end
end
