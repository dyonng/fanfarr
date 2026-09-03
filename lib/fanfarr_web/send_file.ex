defmodule FanfarrWeb.SendFile do
  @moduledoc """
  `Plug.Conn.send_file/3,5`, except a client that has already gone does not
  read as a crash.

  Verified by reproduction, not guessed at: opening a raw socket, sending a
  valid ranged GET for the theme route, and closing it before reading anything
  back -- exactly what a browser's `<audio>` element does when it fires an
  initial probe request and then immediately supersedes it with the real one
  -- raises `Bandit.TransportError, error: :closed` from inside
  `Plug.Conn.send_file/5`, every time. In dev that becomes a debug-page 500;
  in prod it is an application crash, complete with stack trace, logged by
  Phoenix's own error rendering, once per interrupted probe. Every library
  page load fires several of these for posters and the theme player, so this
  was never a rare edge case -- it was most of what filled the console.

  The distinction that matters is Bandit's own: `:closed`, `:enotconn`,
  `:einval`, `:econnaborted` and `:econnreset` are what a departed peer looks
  like, mirroring the exact list `Bandit.Logger` uses to decide whether a
  transport error is worth alarming about (it is not, by default, for exactly
  this reason). Anything else re-raises with its original stacktrace, because
  a transport error that is *not* explained by the client leaving might be a
  real problem, and this module has no business hiding it.
  """
  require Logger

  @client_gone [:closed, :enotconn, :einval, :econnaborted, :econnreset]

  @doc "Wraps `Plug.Conn.send_file/3`."
  @spec file(Plug.Conn.t(), Plug.Conn.status(), Path.t()) :: Plug.Conn.t()
  def file(conn, status, path) do
    Plug.Conn.send_file(conn, status, path)
  rescue
    e in Bandit.TransportError -> handle(conn, e, __STACKTRACE__)
  end

  @doc "Wraps `Plug.Conn.send_file/5`, for a byte range."
  @spec file(Plug.Conn.t(), Plug.Conn.status(), Path.t(), integer(), integer() | :all) ::
          Plug.Conn.t()
  def file(conn, status, path, offset, length) do
    Plug.Conn.send_file(conn, status, path, offset, length)
  rescue
    e in Bandit.TransportError -> handle(conn, e, __STACKTRACE__)
  end

  defp handle(conn, %Bandit.TransportError{error: reason} = e, _stacktrace)
       when reason in @client_gone do
    Logger.debug("theme/poster stream interrupted, client gone: #{Exception.message(e)}")

    # send_file itself sets this on success; setting it by hand after catching
    # the failed attempt is what stops Phoenix from treating an unsent conn as
    # a bug and rendering ITS OWN 500 on top of the one we just swallowed.
    # There is nothing left to write to -- the socket is the thing that broke.
    %{conn | state: :sent}
  end

  defp handle(_conn, e, stacktrace), do: reraise(e, stacktrace)
end
