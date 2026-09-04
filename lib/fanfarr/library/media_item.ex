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
    defaults [:read]

    default_accept :*

    # Deleting an item takes its theme history with it. The foreign key would
    # refuse the delete otherwise -- SQLite enforces it and the constraint has
    # no ON DELETE CASCADE -- so this is what makes removing an item Plex has
    # dropped possible at all.
    #
    # It is a real loss and worth being clear about: a theme uploaded to Plex
    # cannot be undone through its API, so for :api_upload rows this deletes
    # the only record that the upload ever happened. Sync therefore pairs off
    # renames first (see Fanfarr.Workers.SyncSection) and only deletes what is
    # actually gone.
    destroy :destroy do
      primary? true
      require_atomic? false
      transaction? true

      # Before, not after. Ash's own `cascade_destroy` is an after-action hook,
      # which suits a database that defers its constraint checks; SQLite checks
      # immediately, so by then the delete has already been refused. Clearing
      # the children first is the order the constraint actually allows, and the
      # transaction is what makes the pair atomic.
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          changeset.data.id
          |> Fanfarr.Themes.theme_history_for_item!()
          |> Enum.each(&Fanfarr.Themes.delete_theme_application!/1)

          changeset
        end)
      end
    end

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
        :critic_score,
        :critic_score_source,
        :audience_score,
        :audience_score_source,
        :plex_theme_url,
        :plex_theme_origin,
        :plex_theme_agent,
        :theme_locked,
        :added_at
      ]

      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end

    # Point an existing row at the ratingKey Plex now uses for the same thing.
    #
    # Rename a folder and Plex does not update the item: it drops the old
    # ratingKey and issues a new one. Treated naively that is a delete and a
    # create, which throws away everything this row carries that Plex does not
    # know about -- the operator's chosen theme, and the whole application log.
    # Re-keying says what actually happened: same title, new id.
    update :adopt_plex_rating_key do
      accept [:plex_rating_key]
    end

    update :record_local_theme do
      accept [:local_theme_present, :local_theme_path]
      change set_attribute(:local_theme_checked_at, &DateTime.utc_now/0)
    end

    # What Plex serves for one item, re-read on demand rather than waiting for
    # the next full sync. Asking Plex to refresh an item and then reporting
    # what it now serves is the only way to tell "the local file was picked up"
    # from "Plex is still playing its agent's theme", and those two look
    # identical from here otherwise.
    update :record_plex_theme do
      accept [:plex_theme_url, :plex_theme_origin, :plex_theme_agent, :theme_locked]
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end

    # The operator's own pick, chosen from a YouTube search or pasted in. It
    # outranks ThemerrDB from then on, so a re-apply after a Plex refresh
    # reuses the choice rather than reverting to the database's suggestion.
    update :set_manual_theme do
      accept [:manual_theme_url, :manual_theme_title]
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

    # Ratings come from Plex rather than from Rotten Tomatoes, TMDB or TVDB
    # directly, because Plex has already been to those and is already being
    # asked for this item on every sync. Going to them ourselves would mean an
    # API key to configure, a rate limit to respect and a second opinion that
    # could disagree with what the operator sees in Plex -- for a number that
    # arrives free in a response we are already reading.
    #
    # Both are stored on Plex's own 0-10 scale whatever the provider, which is
    # what makes them sortable against each other. Rotten Tomatoes' native form
    # is a percentage and is rendered that way; see `Fanfarr.Library.Score`.
    attribute :critic_score, :float do
      public? true
      description "Plex's `rating`: the critic score, 0-10, whoever supplied it."
    end

    attribute :critic_score_source, :string do
      public? true
      description "Which service the critic score came from -- rottentomatoes, imdb, themoviedb."
    end

    attribute :audience_score, :float do
      public? true
      description "Plex's `audienceRating`, 0-10."
    end

    attribute :audience_score_source, :string do
      public? true
      description "Which service the audience score came from."
    end

    attribute :plex_theme_url, :string do
      public? true
      description "The theme Plex currently has, if any."
    end

    attribute :plex_theme_origin, :atom do
      public? true
      allow_nil? false
      default :none
      constraints one_of: [:none, :plex_agent, :local, :uploaded, :unknown]

      description """
      Where the theme Plex is serving came from, read from the ratingKey scheme
      on /library/metadata/<id>/themes. Plex sends no `provider` field -- an
      earlier version of this read one and it was always nil.

      :plex_agent is the case the dashboard exists to surface: a title that
      looks "done" but only carries Plex's own stock theme.
      """
    end

    attribute :plex_theme_agent, :string do
      public? true

      description "The agent that supplied the theme, e.g. tv.plex.agents.series."
    end

    attribute :theme_locked, :boolean, default: false, public?: true

    attribute :manual_theme_url, :string do
      public? true

      description """
      A theme the operator chose by hand -- from the in-app YouTube search or
      pasted in. When set, this is what gets applied; ThemerrDB is only the
      fallback for items with no manual pick.
      """
    end

    attribute :manual_theme_title, :string do
      public? true
      description "The video title at the time it was picked, for the dashboard."
    end

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
