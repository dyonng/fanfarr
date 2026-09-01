defmodule Fanfarr.Accounts.User.Validations.OnlyFirstUser do
  @moduledoc """
  Permits registration only while no user exists.

  Fanfarr is single-user. The first visit to a fresh install creates the
  operator's account, after which the register form stops working -- the same
  shape as the *arr first-run flow. Without this, anyone who can reach the
  port could add themselves an account.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(_changeset, _opts, _context) do
    case Ash.read(Fanfarr.Accounts.User, authorize?: false) do
      {:ok, []} ->
        :ok

      {:ok, _users} ->
        {:error,
         field: :email, message: "registration is disabled: this server already has its user"}

      {:error, error} ->
        {:error, error}
    end
  end
end
