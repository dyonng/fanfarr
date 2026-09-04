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
    resource Fanfarr.Themes.ThemerrEntry do
      define :record_themerr_lookup, action: :record_lookup
      define :list_stale_themerr_entries, action: :stale
      define :list_themerr_entries, action: :read

      define :themerr_entries_by_external_ids,
        action: :by_external_ids,
        args: [:external_ids]

      define :themerr_entry_for,
        action: :lookup,
        args: [:item_type, :database, :external_id],
        get?: true
    end

    resource Fanfarr.Themes.ThemeApplication do
      define :record_theme_intent, action: :record_intent
      define :record_theme_outcome, action: :record_outcome
      define :theme_history_for_item, action: :for_item, args: [:media_item_id]
      define :list_theme_failures, action: :failures
      define :list_theme_applications, action: :read
      # Called only from MediaItem's destroy. See that action, and this
      # resource's moduledoc, for why the log has a delete at all.
      define :delete_theme_application, action: :destroy_with_item
    end
  end
end
