defmodule Fanfarr.Themes do
  @moduledoc """
  Theme resolution and the record of what has been applied.

  Two resources with very different lifetimes. `ThemerrEntry` is a cache and may
  be discarded at any time. `ThemeApplication` is an append-only log and must
  not be: theme uploads cannot be undone through Plex's API, so the log is the
  only record of what we did to someone's server.
  """
  use Ash.Domain, otp_app: :fanfarr, extensions: [AshJsonApi.Domain]

  resources do
    resource Fanfarr.Themes.ThemerrEntry
    resource Fanfarr.Themes.ThemeApplication
  end
end
