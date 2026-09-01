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
    resource Fanfarr.Library.Section do
      define :list_sections, action: :read
      define :get_section, action: :read, get_by: [:id]
      define :sync_section_from_plex, action: :sync_from_plex
      define :set_section_enabled, action: :set_enabled, args: [:enabled]
    end

    resource Fanfarr.Library.MediaItem do
      define :list_media_items, action: :read
      define :get_media_item, action: :read, get_by: [:id]
      define :media_items_in_section, action: :by_section, args: [:section_id]
      define :sync_media_item_from_plex, action: :sync_from_plex
      define :record_local_theme, action: :record_local_theme
    end

    resource Fanfarr.Library.RootFolder do
      define :list_root_folders, action: :read
      define :get_root_folder, action: :read, get_by: [:id]
      define :list_enabled_root_folders, action: :enabled
      define :create_root_folder, action: :create
      define :update_root_folder, action: :update
      define :delete_root_folder, action: :destroy
      define :record_root_folder_check, action: :record_check
    end
  end
end
