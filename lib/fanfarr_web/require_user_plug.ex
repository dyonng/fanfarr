defmodule FanfarrWeb.RequireUserPlug do
  @moduledoc """
  Plug counterpart of `FanfarrWeb.LiveUserAuth`'s `:live_user_required`: lets
  a request through when a user is signed in, when authentication is off
  because no operator account was configured, or when it comes from a local
  address and Settings has the local-network bypass turned on. Used for
  non-LiveView routes that show the same data the dashboard does.
  """
  @behaviour Plug

  import Plug.Conn

  alias Fanfarr.Accounts.AuthMode

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      conn.assigns[:current_user] -> conn
      not AuthMode.required?(AuthMode.bypass_for_request?(conn)) -> conn
      true -> conn |> send_resp(401, "sign in required") |> halt()
    end
  end
end
