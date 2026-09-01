defmodule Fanfarr.Library.MediaItem do
  @moduledoc """
  One show or movie, mirrored from Plex.

  Theme status is **calculated**, never stored. The brief asks us to distinguish
  five states that Themerr conflated, and each is a conclusion drawn from facts
  we already hold: what Plex reports, whether a local theme.mp3 exists, and what
  our own append-only application log says. A stored status column would be a
  sixth fact that has to be kept in step with the other three, and it would
  eventually disagree with them.
  """
  use Ash.Resource,
    otp_app: :fanfarr,
    domain: Fanfarr.Library,
    data_layer: AshSqlite.DataLayer

  alias Fanfarr.Library.MediaItem.ThemeStatus

  sqlite do
    table "library_media_items"
    repo Fanfarr.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept :*

    create :create do
      primary? true
      accept :*
    end

    update :update do
      primary? true
      require_atomic? false
      accept :*
    end

    # Sync rewrites Plex-owned fields and leaves our own observations alone.
    # local_theme_present in particular is set by the filesystem scan, which
    # runs separately and would otherwise be clobbered on every library sync.
    create :sync_from_plex do
      upsert? true
      upsert_identity :unique_plex_rating_key

      accept [
        :plex_rating_key,
        :section_id,
        :guid,
        :title,
        :year,
        :kind,
        :plex_path,
        :imdb_id,
        :tmdb_id,
        :tvdb_id,
        :plex_thumb_key,
        :plex_theme_url,
        :plex_theme_provider,
        :theme_locked,
        :added_at
      ]

      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end

    update :record_local_theme do
      accept [:local_theme_present, :local_theme_path]
      change set_attribute(:local_theme_checked_at, &DateTime.utc_now/0)
    end

    read :by_section do
      argument :section_id, :uuid, allow_nil?: false
      filter expr(section_id == ^arg(:section_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :plex_rating_key, :string do
      allow_nil? false
      public? true
      description "Plex's per-item id. Every API call about this item is keyed on it."
    end

    attribute :guid, :string, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :year, :integer, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:show, :movie]
    end

    attribute :plex_path, :string do
      public? true

      description """
      The directory Plex reports for this item, in Plex's own view of the
      filesystem. Translate with Fanfarr.PathMapping before touching disk.
      """
    end

    # ThemerrDB is keyed on these, and it accepts imdb or themoviedb. Which of
    # the three Plex supplies varies by agent, so all are kept.
    attribute :imdb_id, :string, public?: true
    attribute :tmdb_id, :string, public?: true
    attribute :tvdb_id, :string, public?: true

    attribute :plex_thumb_key, :string do
      public? true
      description "Poster path within Plex. Cached to disk rather than fetched per render."
    end

    attribute :plex_theme_url, :string do
      public? true
      description "The theme Plex currently has, if any."
    end

    attribute :plex_theme_provider, :string do
      public? true

      description """
      Plex reports 'local' for a theme.mp3 found on disk, and nil for one that
      was uploaded or supplied by an agent. Not sufficient on its own to tell
      our uploads from Plex's own, which is why we keep an application log.
      """
    end

    attribute :theme_locked, :boolean, default: false, public?: true

    attribute :local_theme_present, :boolean do
      allow_nil? false
      default false
      public? true

      description "Whether a theme.mp3 exists on disk. Set by the filesystem scan, not by library sync."
    end

    attribute :local_theme_path, :string, public?: true
    attribute :local_theme_checked_at, :utc_datetime_usec, public?: true

    attribute :added_at, :utc_datetime_usec, public?: true
    attribute :last_synced_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :section, Fanfarr.Library.Section do
      allow_nil? false
      attribute_writable? true
      # Without this the generated foreign key stays private, so `accept :*`
      # silently excludes it and every create fails on a missing relationship.
      attribute_public? true
    end

    has_many :theme_applications, Fanfarr.Themes.ThemeApplication
  end

  calculations do
    calculate :theme_status, :atom, ThemeStatus do
      public? true

      description """
      One of :missing, :failed, :local_file, :fanfarr_applied or :plex_supplied.
      """
    end
  end

  identities do
    identity :unique_plex_rating_key, [:plex_rating_key]
  end
end
