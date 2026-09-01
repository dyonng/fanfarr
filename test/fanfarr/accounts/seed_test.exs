defmodule Fanfarr.Accounts.SeedTest do
  @moduledoc """
  Credential reconciliation from the environment. The behaviour that matters
  is that compose is the source of truth: editing it and restarting must be
  the whole story for creating, changing and removing the login.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Accounts.AuthMode
  alias Fanfarr.Accounts.Seed
  alias Fanfarr.Accounts.User

  setup do
    on_exit(fn ->
      System.delete_env("AUTH_USERNAME")
      System.delete_env("AUTH_PASSWORD")
    end)

    System.delete_env("AUTH_USERNAME")
    System.delete_env("AUTH_PASSWORD")
    :ok
  end

  defp set_env(user, pass) do
    System.put_env("AUTH_USERNAME", user)
    System.put_env("AUTH_PASSWORD", pass)
  end

  defp users, do: Ash.read!(User, authorize?: false)

  defp sign_in(username, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{username: username, password: password})
    |> Ash.read_one(authorize?: false)
  end

  test "creates the operator account from the environment" do
    set_env("admin", "a-long-password")
    Seed.run()

    assert [user] = users()
    assert to_string(user.username) == "admin"
    assert AuthMode.required?()
  end

  test "is idempotent across restarts" do
    set_env("admin", "a-long-password")
    Seed.run()
    Seed.run()

    assert length(users()) == 1
  end

  test "changing AUTH_PASSWORD takes effect on the next boot" do
    set_env("admin", "original-password")
    Seed.run()
    assert {:ok, _} = sign_in("admin", "original-password")

    # The whole recovery story: edit compose, restart.
    set_env("admin", "replacement-password")
    Seed.run()

    assert {:ok, _} = sign_in("admin", "replacement-password")
    assert {:error, _} = sign_in("admin", "original-password")
  end

  test "renaming AUTH_USERNAME does not leave the old login working" do
    set_env("admin", "a-long-password")
    Seed.run()

    set_env("operator", "a-long-password")
    Seed.run()

    assert [user] = users()
    assert to_string(user.username) == "operator"
    assert {:error, _} = sign_in("admin", "a-long-password")
  end

  test "unsetting the variables disables authentication and clears the account" do
    set_env("admin", "a-long-password")
    Seed.run()
    assert AuthMode.required?()

    System.delete_env("AUTH_USERNAME")
    System.delete_env("AUTH_PASSWORD")
    assert :open = Seed.run()

    # Leaving the account behind would strand a login whose password is no
    # longer written down anywhere.
    assert users() == []
    refute AuthMode.required?()
  end

  test "a username with no password is treated as unset rather than half-configured" do
    System.put_env("AUTH_USERNAME", "admin")
    assert :open = Seed.run()
    assert users() == []
  end

  test "blank values are treated as unset" do
    set_env("   ", "")
    assert :open = Seed.run()
    assert users() == []
  end
end
