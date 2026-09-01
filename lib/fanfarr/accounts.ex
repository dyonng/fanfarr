defmodule Fanfarr.Accounts do
  use Ash.Domain,
    otp_app: :fanfarr

  resources do
    resource Fanfarr.Accounts.Token
    resource Fanfarr.Accounts.User
  end
end
