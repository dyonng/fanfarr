defmodule Fanfarr.Themes.ThemerrEntry do
  @moduledoc """
  A cached ThemerrDB lookup.

  ThemerrDB has no bulk endpoint, so a cold sync of a few thousand titles is a
  few thousand HTTP requests. Caching is not an optimisation here, it is what
  makes routine re-syncing viable at all.

  Misses are cached too. Most of a library is not in ThemerrDB, and without
  negative caching every sync would re-request every absent title forever.

  The important column is `youtube_theme_edited`, which upstream ignores. It is
  ThemerrDB's own record of when a theme last changed, so comparing it tells us
  whether anything actually needs re-resolving -- independently of when we last
  looked. A refresh that finds an unchanged timestamp is finished.
  """
  use Ash.Resource,
    otp_app: :fanfarr,
    domain: Fanfarr.Themes,
    data_layer: AshSqlite.DataLayer

  # For the filter macro used in the :stale preparation below.
  require Ash.Query

  sqlite do
    table "themerr_entries"
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

    create :record_lookup do
      upsert? true
      upsert_identity :unique_lookup

      accept [
        :item_type,
        :database,
        :external_id,
        :found,
        :youtube_theme_url,
        :youtube_theme_added,
        :youtube_theme_edited
      ]

      change set_attribute(:fetched_at, &DateTime.utc_now/0)
    end

    read :lookup do
      argument :item_type, :atom, allow_nil?: false
      argument :database, :atom, allow_nil?: false
      argument :external_id, :string, allow_nil?: false

      filter expr(
               item_type == ^arg(:item_type) and database == ^arg(:database) and
                 external_id == ^arg(:external_id)
             )
    end

    # The library table asks about a page of items at once. One query keyed on
    # the external ids they mention beats a hundred lookups.
    read :by_external_ids do
      argument :external_ids, {:array, :string}, allow_nil?: false
      filter expr(external_id in ^arg(:external_ids))
    end

    read :stale do
      argument :ttl_seconds, :integer, default: 86_400

      # The cutoff is computed here rather than with `ago/2` in an expression.
      # AshSqlite implements only `like` and `ilike` as custom functions, so
      # `ago/2` does not translate -- and it fails by matching nothing rather
      # than by raising, which would leave a refresh job quietly doing no work.
      prepare fn query, _context ->
        ttl = Ash.Query.get_argument(query, :ttl_seconds)
        cutoff = DateTime.add(DateTime.utc_now(), -ttl, :second)
        Ash.Query.filter(query, fetched_at < ^cutoff)
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :item_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:movies, :tv_shows]
      description "ThemerrDB's own naming, which differs from Plex's show/movie."
    end

    attribute :database, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:imdb, :themoviedb, :thetvdb]

      description "thetvdb is unverified -- the reference implementation only ever uses the first two."
    end

    attribute :external_id, :string, allow_nil?: false, public?: true

    attribute :found, :boolean do
      allow_nil? false
      default false
      public? true

      description "False records a 404. Absent titles are the common case and must not be re-requested every cycle."
    end

    attribute :youtube_theme_url, :string, public?: true

    attribute :youtube_theme_added, :integer do
      public? true
      description "Unix timestamp from ThemerrDB."
    end

    attribute :youtube_theme_edited, :integer do
      public? true

      description """
      Unix timestamp of ThemerrDB's last edit. The change key: if this has not
      moved, the theme has not changed and nothing needs re-resolving.
      """
    end

    attribute :fetched_at, :utc_datetime_usec, allow_nil?: false, public?: true

    timestamps()
  end

  identities do
    identity :unique_lookup, [:item_type, :database, :external_id]
  end
end
