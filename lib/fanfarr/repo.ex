defmodule Fanfarr.Repo do
  use AshSqlite.Repo,
    otp_app: :fanfarr

  # Always the bundled copy: exqlite compiles SQLite from its own C sources,
  # currently 3.54.1, so no system SQLite ever answers here.
  def min_sqlite_version do
    %Version{major: 3, minor: 54, patch: 1}
  end
end
