defmodule FanfarrWeb.AuthController do
  use FanfarrWeb, :controller
  use AshAuthentication.Phoenix.Controller

  @impl true
  def success(conn, activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    message =
      case activity do
        {:confirm_new_user, :confirm} -> "Your email address has now been confirmed"
        {:password, :reset} -> "Your password has successfully been reset"
        _ -> "You are now signed in"
      end

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  @impl true
  def failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          """
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """

        _ ->
          "Incorrect email or password"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  @impl true
  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:fanfarr)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end

  # The library's own default forces `secure: true` outside :dev, which would
  # silently break "remember me" for the common case here: an appliance
  # reached over plain HTTP on a LAN. Nothing else in this app makes that
  # assumption -- the session cookie above sets no such flag either -- so
  # Secure is decided from the request actually being served. `conn.scheme`
  # already reflects X-Forwarded-Proto via Plug.RewriteOn in the endpoint, so
  # a deployment that does put TLS in front still gets a Secure cookie.
  @impl true
  def put_remember_me_cookie(conn, cookie_name, %{token: token, max_age: max_age}) do
    put_resp_cookie(conn, cookie_name, token,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      max_age: max_age
    )
  end
end
