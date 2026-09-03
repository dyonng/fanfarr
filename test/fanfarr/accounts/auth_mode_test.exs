defmodule Fanfarr.Accounts.AuthModeTest do
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Accounts.AuthMode

  describe "bypass_enabled?/0 and set_bypass_enabled/1" do
    test "is off by default" do
      refute AuthMode.bypass_enabled?()
    end

    test "round-trips through Settings" do
      AuthMode.set_bypass_enabled(true)
      assert AuthMode.bypass_enabled?()

      AuthMode.set_bypass_enabled(false)
      refute AuthMode.bypass_enabled?()
    end
  end

  describe "required?/1" do
    test "with no operator account, login is never required regardless of bypass" do
      refute AuthMode.required?()
      refute AuthMode.required?(true)
      refute AuthMode.required?(false)
    end

    test "with an operator account, bypassed? decides" do
      register_operator()

      assert AuthMode.required?()
      assert AuthMode.required?(false)
      refute AuthMode.required?(true)
    end
  end

  describe "bypass_for_request?/1" do
    test "false when the setting is off, even from a local address" do
      conn = %Plug.Conn{remote_ip: {127, 0, 0, 1}}
      refute AuthMode.bypass_for_request?(conn)
    end

    test "false from a non-local address, even when the setting is on" do
      AuthMode.set_bypass_enabled(true)
      conn = %Plug.Conn{remote_ip: {8, 8, 8, 8}}
      refute AuthMode.bypass_for_request?(conn)
    end

    test "true only when the setting is on and the address is local" do
      AuthMode.set_bypass_enabled(true)
      conn = %Plug.Conn{remote_ip: {192, 168, 1, 50}}
      assert AuthMode.bypass_for_request?(conn)
    end
  end

  defp register_operator do
    Fanfarr.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      username: "operator",
      password: "a-long-password",
      password_confirmation: "a-long-password"
    })
    |> Ash.create!(authorize?: false)
  end
end
