defmodule Fanfarr.Accounts.AuthMode do
  @moduledoc """
  Whether a login is required.

  Derived from whether an operator account exists, which the boot-time seeder
  keeps in step with AUTH_USERNAME/AUTH_PASSWORD. Deriving it from the data
  rather than re-reading the environment means the answer cannot disagree with
  what would actually happen at the sign-in form.
  """
  def required? do
    case Ash.read(Fanfarr.Accounts.User, authorize?: false) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end
end
