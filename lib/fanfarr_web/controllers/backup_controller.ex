defmodule FanfarrWeb.BackupController do
  @moduledoc """
  Hands back a database snapshot, so it can be kept somewhere other than the
  machine it was taken on -- which is the only thing that makes a snapshot
  protection against that machine failing.

  A snapshot is the whole of what Fanfarr knows, and that includes the Plex
  token and the dashboard's password hash. Three consequences, all deliberate:

    * it is served behind the same session gate as the media routes, not as a
      public file;
    * it is sent as an attachment with `no-store`, so neither a browser nor an
      intermediary keeps a copy of a secrets file in a cache;
    * every download is logged, because "who took a copy of the database, and
      when" is a question worth being able to answer.

  The name in the URL is matched against the snapshots that actually exist on
  disk. The path never comes from the request, the same rule the theme endpoint
  follows -- and the same reason.
  """
  use FanfarrWeb, :controller

  require Logger

  def download(conn, %{"name" => name}) do
    case Enum.find(Fanfarr.Backup.list(), &(&1.name == name)) do
      %{path: path} ->
        Logger.info("[fanfarr] database snapshot downloaded: #{name}")

        conn
        |> put_resp_content_type("application/vnd.sqlite3")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
        |> put_resp_header("cache-control", "no-store")
        |> send_file(200, path)

      _ ->
        send_resp(conn, 404, "no such snapshot")
    end
  end
end
