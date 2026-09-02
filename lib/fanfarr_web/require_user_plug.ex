defmodule FanfarrWeb.RequireUserPlug do
  @moduledoc """
  Plug counterpart of `FanfarrWeb.LiveUserAuth`'s `:live_user_required`: lets
  a request through when a user is signed in, or when authentication is off
  because no operator account was configured. Used for non-LiveView routes
  that show the same data the dashboard does.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      conn.assigns[:current_user] -> conn
      not Fanfarr.Accounts.AuthMode.required?() -> conn
      true -> conn |> send_resp(401, "sign in required") |> halt()
    end
  end
end
