defmodule FanfarrWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FanfarrWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FanfarrWeb.Endpoint

      use FanfarrWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FanfarrWeb.ConnCase
    end
  end

  @doc """
  Creates the operator account and signs the conn in as them.

  Mirrors what the boot-time seeder does from AUTH_USERNAME/AUTH_PASSWORD.

      setup :register_and_log_in_user
  """
  def register_and_log_in_user(%{conn: conn}) do
    user =
      Fanfarr.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        username: "operator",
        password: "a-long-password",
        password_confirmation: "a-long-password"
      })
      |> Ash.create!(authorize?: false)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    %{conn: conn, user: user}
  end

  setup tags do
    Fanfarr.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
