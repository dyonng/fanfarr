defmodule FanfarrWeb.LocalBypassPlug do
  @moduledoc """
  Sends a request that the local-address bypass already admits past the
  sign-in form instead of showing it.

  With "disable authentication for local addresses" on, a visitor from the LAN
  already has every page; the form asks them for credentials they do not need,
  and signing in lands them exactly where they could already go. Worse, it
  reads as a wall: the machine appears to demand a password that, in this
  configuration, was never the thing keeping anyone out.

  A plug rather than a `on_mount` hook on the sign-in LiveView, because the
  decision needs `conn.remote_ip` -- the real TCP peer, never a header, per
  `Fanfarr.Accounts.LocalNetwork` -- and that only exists on this side of the
  socket. The authenticated routes solve the same problem by stashing the
  answer in the session (`FanfarrWeb.LiveUserAuth.extra_session/1`); here the
  conn is right at hand, so there is nothing to stash.

  Deliberately not applied to `/sign-out`: signing out is a real action even
  for someone the bypass will then let straight back in, and bouncing it would
  leave a stale session behind.
  """
  @behaviour Plug

  use FanfarrWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Fanfarr.Accounts.AuthMode

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if AuthMode.bypass_for_request?(conn) do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end
end
