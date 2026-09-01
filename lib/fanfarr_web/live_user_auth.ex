defmodule FanfarrWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use FanfarrWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {FanfarrWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    cond do
      socket.assigns[:current_user] ->
        {:cont, socket}

      # No operator account means AUTH_USERNAME/AUTH_PASSWORD are unset and
      # authentication is off, the way the *arrs start. Redirecting to a
      # sign-in form nobody has credentials for would lock the dashboard
      # instead of opening it.
      not Fanfarr.Accounts.AuthMode.required?() ->
        {:cont, Phoenix.Component.assign(socket, :current_user, nil)}

      true ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    cond do
      socket.assigns[:current_user] ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}

      # Authentication is optional. With AUTH_USERNAME/AUTH_PASSWORD unset
      # there is no account, so a sign-in form asks for credentials that do
      # not exist -- a dead end. Send visitors to the dashboard instead.
      not Fanfarr.Accounts.AuthMode.required?() ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}

      true ->
        {:cont, assign(socket, :current_user, nil)}
    end
  end
end
