defmodule Fanfarr.Library do
  @moduledoc """
  A local mirror of the Plex library.

  Fanfarr does not query Plex to render the dashboard. Plex's API is slow enough
  that a grid of a few thousand items would be unusable, and Themerr hit the
  same wall -- it grew a cache task for exactly this reason. Instead a sync job
  writes Plex's state into SQLite on a schedule and every read is served from
  here.

  The mirror is therefore always slightly stale, and that is fine: nothing here
  is authoritative. Plex owns the library; these rows are a fast copy of what it
  said last time we asked.
  """
  use Ash.Domain, otp_app: :fanfarr, extensions: [AshJsonApi.Domain]

  resources do
    resource Fanfarr.Library.Section
    resource Fanfarr.Library.MediaItem
    resource Fanfarr.Library.RootFolder
  end
end
