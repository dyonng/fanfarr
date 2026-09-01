defmodule FanfarrWeb.HealthController do
  @moduledoc """
  Liveness endpoint for the container healthcheck and for uptime monitoring.

  Deliberately shallow: it confirms the app is up and can reach its database,
  and nothing more. Checks that depend on the outside world -- Plex being
  reachable, ThemerrDB responding, yt-dlp working -- belong in the dashboard's
  health panel, where a failure is information rather than a reason for Docker
  to restart the container. A YouTube outage must not cause a restart loop.
  """
  use FanfarrWeb, :controller

  def show(conn, _params) do
    case database_status() do
      :ok ->
        json(conn, %{status: "ok", version: version()})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: reason, version: version()})
    end
  end

  defp database_status do
    case Ecto.Adapters.SQL.query(Fanfarr.Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Same string the sidebar shows, so a bug report quoting either is unambiguous.
  defp version, do: Fanfarr.Version.display()
end
