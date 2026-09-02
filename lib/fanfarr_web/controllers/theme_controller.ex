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
  """
  use FanfarrWeb, :controller

  require Logger

  def show(conn, %{"id" => id}) do
    with {:ok, item} <- Fanfarr.Library.get_media_item(id),
         path when is_binary(path) <- item.local_theme_path,
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type(content_type(path))
      # The file changes in place when a theme is replaced, and the URL does
      # not, so it must not be cached.
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("accept-ranges", "none")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "no theme file for this item")
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
