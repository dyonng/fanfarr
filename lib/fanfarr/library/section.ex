defmodule Fanfarr.Library.Section do
  @moduledoc """
  A Plex library section -- one "TV Shows" or "Movies" library.

  Sections are enabled individually. A homelab commonly has libraries Fanfarr
  has no business touching (home video, personal recordings), and uploading
  themes is irreversible through Plex's API, so the safe default is that a newly
  discovered section is *disabled* until someone opts it in.
  """
  use Ash.Resource,
    otp_app: :fanfarr,
    domain: Fanfarr.Library,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "library_sections"
    repo Fanfarr.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:title, :kind, :plex_locations, :enabled]

    create :create do
      primary? true
      accept [:plex_key, :title, :kind, :plex_locations, :enabled]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:title, :kind, :plex_locations, :enabled]
    end

    # Sync sees every section on every run, so this is an upsert rather than a
    # create: a section that already exists has its metadata refreshed, and
    # `enabled` is deliberately absent from the accepted fields so a sync can
    # never re-enable something the operator turned off.
    create :sync_from_plex do
      upsert? true
      upsert_identity :unique_plex_key
      accept [:plex_key, :title, :kind, :plex_locations]

      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end

    update :set_enabled do
      accept [:enabled]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :plex_key, :string do
      allow_nil? false
      public? true
      description "Plex's own identifier for the section, stable across restarts."
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:show, :movie]

      description "Plex calls these 'show' and 'movie'; ThemerrDB calls the same things tv_shows and movies."
    end

    # Plex reports one or more filesystem locations per section. Stored as a
    # list so the health check can verify each one resolves locally, which is
    # what separates "no themes were written" from "the mount is wrong".
    attribute :plex_locations, {:array, :string} do
      default []
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default false
      public? true
      description "Off by default: theme uploads cannot be undone through Plex's API."
    end

    attribute :last_synced_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    has_many :media_items, Fanfarr.Library.MediaItem
  end

  identities do
    identity :unique_plex_key, [:plex_key]
  end
end
