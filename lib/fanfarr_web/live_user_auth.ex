defmodule FanfarrWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use FanfarrWeb, :verified_routes

  @doc """
  Passed to `ash_authentication_live_session` as its `:session` hook so the
  local-address bypass decision -- which needs the conn's real `remote_ip`,
  not available once we're down to a socket -- rides along in the (narrow)
  session LiveView mounts and reconnects with, for `:live_user_required`
  below to read back.
  """
  def extra_session(conn) do
    %{"local_bypass" => Fanfarr.Accounts.AuthMode.bypass_for_request?(conn)}
  end

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

  def on_mount(:live_user_required, _params, session, socket) do
    cond do
      socket.assigns[:current_user] ->
        {:cont, socket}

      # Either no operator account exists -- AUTH_USERNAME/AUTH_PASSWORD are
      # unset and authentication is off, the way the *arrs start -- or one
      # does but Settings has "disable authentication for local addresses"
      # on and this request came from one (decided in `extra_session/1`,
      # since only the conn that generated this session knows the real
      # remote_ip). Either way, redirecting to a sign-in form would just be
      # in the way.
      not Fanfarr.Accounts.AuthMode.required?(session["local_bypass"] || false) ->
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
