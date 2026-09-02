defmodule FanfarrWeb.PosterController do
  @moduledoc """
  Serves an item's poster from the disk cache, fetching it from Plex on the
  first request. See `Fanfarr.Posters` for why the browser never talks to Plex.
  """
  use FanfarrWeb, :controller

  # Posters change when Plex's thumb key changes, and that key is part of the
  # cache filename, so a URL can be cached by the browser for a long time.
  @cache_control "public, max-age=604800"

  def show(conn, %{"id" => id}) do
    with {:ok, item} <- Fanfarr.Library.get_media_item(id),
         {:ok, path, type} <- Fanfarr.Posters.path_for(item) do
      conn
      |> put_resp_content_type(type)
      |> put_resp_header("cache-control", @cache_control)
      |> send_file(200, path)
    else
      _ ->
        # A blank, so a missing poster is an empty frame rather than a broken
        # image icon. Short-lived, so it is retried once Plex is reachable.
        conn
        |> put_resp_content_type("image/svg+xml")
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, placeholder())
    end
  end

  defp placeholder do
    ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2 3"><rect width="2" height="3" fill="#2a2f36"/></svg>)
  end
end
