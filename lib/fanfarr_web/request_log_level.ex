defmodule FanfarrWeb.RequestLogLevel do
  @moduledoc """
  Decides the log level for each request.

  Exists for one reason: the container healthcheck polls `/health` every 30
  seconds, and Phoenix logs two lines per request. That is roughly 5,800 lines
  a day describing nothing happening -- enough to bury an actual error and to
  cycle the container's capped log files well before anything interesting
  falls off the end.

  Those requests drop to `:debug` rather than being silenced outright, so they
  are still there when someone is deliberately debugging the healthcheck.
  Everything else keeps the usual `:info`.
  """

  @quiet_paths ["/health"]

  @doc """
  Called by `Plug.Telemetry` with the conn; returns a `Logger` level.

  Configured as `log: {FanfarrWeb.RequestLogLevel, :for_conn, []}` on the
  telemetry plug in the endpoint.
  """
  def for_conn(%Plug.Conn{request_path: path}) when path in @quiet_paths, do: :debug
  def for_conn(_conn), do: :info
end
