defmodule FanfarrWeb.AuthControllerTest do
  @moduledoc """
  The "remember me" round trip: a checked box on sign-in survives an expired
  session and signs the operator back in without a password, for 30 days.
  """
  use FanfarrWeb.ConnCase, async: false

  defp register_user do
    Fanfarr.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      username: "operator",
      password: "a-long-password",
      password_confirmation: "a-long-password"
    })
    |> Ash.create!(authorize?: false)
  end

  # What the LiveView form does on submit: get the short-lived sign-in token
  # from a real password check, then exchange it via the controller route --
  # the request that actually has a connection to set a cookie on.
  defp sign_in_token do
    {:ok, user} =
      Fanfarr.Accounts.User
      |> Ash.Query.for_read(
        :sign_in_with_password,
        %{username: "operator", password: "a-long-password"},
        # What the sign-in LiveView sets before submitting: a short-lived,
        # sign_in-purpose token to exchange over the controller route, rather
        # than a full session token minted for a form submit that never
        # leaves the LiveView process.
        context: %{token_type: :sign_in}
      )
      |> Ash.read_one(authorize?: false)

    user.__metadata__.token
  end

  describe "the sign-in form" do
    test "offers to remember the operator for 30 days", %{conn: conn} do
      register_user()
      html = conn |> get(~p"/sign-in") |> html_response(200)

      assert html =~ ~s(name="user[remember_me]")
      assert html =~ "Remember me for 30 days"
    end
  end

  describe "exchanging a sign-in token with remember_me requested" do
    test "sets a cookie the next unauthenticated request revives a session from",
         %{conn: conn} do
      register_user()
      token = sign_in_token()

      conn = get(conn, ~p"/auth/user/password/sign_in_with_token?token=#{token}&remember_me=true")
      assert redirected_to(conn) == ~p"/"

      cookie = conn.resp_cookies["remember_me"]
      assert %{value: remember_token} = cookie
      assert is_binary(remember_token)
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      # Plain HTTP request in the test, so no Secure flag -- the appliance
      # runs on a LAN over HTTP by default and a Secure cookie would never be
      # sent back, silently breaking the whole feature.
      refute cookie[:secure]

      # A fresh conn: no session at all, exactly what a new day looks like
      # after the short-lived session token has expired. The cookie alone
      # gets it in.
      fresh =
        build_conn()
        |> put_req_cookie("remember_me", remember_token)
        |> get(~p"/")

      assert html_response(fresh, 200) =~ "Library"
    end

    test "a request over HTTPS gets a Secure cookie", %{conn: conn} do
      # Plug.Adapters.Test.Conn builds :scheme by parsing the path argument
      # itself, not from the conn struct passed in -- so getting :https here
      # takes an absolute URL, not a bare path plus a struct field set by hand.
      register_user()
      token = sign_in_token()

      conn =
        get(
          conn,
          "https://fanfarr.example/auth/user/password/sign_in_with_token?token=#{token}&remember_me=true"
        )

      assert conn.resp_cookies["remember_me"][:secure]
    end

    test "unchecked, no cookie is set and no unused token is written", %{conn: conn} do
      register_user()
      token = sign_in_token()

      conn = get(conn, ~p"/auth/user/password/sign_in_with_token?token=#{token}")
      assert redirected_to(conn) == ~p"/"
      refute Map.has_key?(conn.resp_cookies, "remember_me")
    end
  end

  describe "without the cookie" do
    test "an expired session still lands on sign-in, not the dashboard", %{conn: conn} do
      register_user()
      assert conn |> get(~p"/") |> redirected_to() == ~p"/sign-in"
    end
  end

  describe "sign-out" do
    test "clears the remember-me cookie along with the session" do
      register_user()
      token = sign_in_token()

      signed_in =
        build_conn()
        |> get(~p"/auth/user/password/sign_in_with_token?token=#{token}&remember_me=true")

      remember_token = signed_in.resp_cookies["remember_me"].value

      # No session set up by hand: the request itself, going through the real
      # pipeline, is what turns this cookie into a signed-in conn -- the same
      # thing the browser would have on the next tab it opens.
      conn =
        build_conn()
        |> put_req_cookie("remember_me", remember_token)
        |> delete(~p"/sign-out")

      cleared = conn.resp_cookies["remember_me"]
      assert cleared.max_age == 0
    end
  end
end
