defmodule Fanfarr.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test.

  ## Why nothing that touches the database is async

  SQLite allows exactly one writer at a time. An async test is its own sandbox
  owner on its own connection, so two of them writing at once do not fail
  themselves: they fail whichever tests happen to be running beside them, in
  files that had nothing to do with each other, and usually in a setup before
  the test body has even started. That is why every case here is
  `async: false`.

  A test that never touches the database should not use this module at all.
  `ExUnit.Case` is async safely -- see the many cases in `test/` that use it
  for parsing, formatting, and the pure modules.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Fanfarr.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Fanfarr.DataCase
    end
  end

  setup tags do
    Fanfarr.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Fanfarr.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
