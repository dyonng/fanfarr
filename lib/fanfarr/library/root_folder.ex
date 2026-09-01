defmodule Fanfarr.Library.RootFolder do
  @moduledoc """
  A configured media location, in the same sense Sonarr and Radarr use the term.

  Fanfarr locates an item by matching its directory name across these, rather
  than by being told which drive holds what -- see `Fanfarr.Library.RootFolders`
  for the resolution itself. That is what lets the container mount libraries at
  `/tv1`, `/tv2` and so on without any of those paths matching what Plex reports.

  On a pooled filesystem they also decide placement: writing to a resolved drive
  keeps a theme on the same disk as its episodes and makes the rename atomic,
  rather than letting the pool's create policy scatter it.

  Optional. With none configured, the path Plex reports is used as given.
  """
  use Ash.Resource,
    otp_app: :fanfarr,
    domain: Fanfarr.Library,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "root_folders"
    repo Fanfarr.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:path, :label, :kind, :enabled]

    create :create do
      primary? true
      accept [:path, :label, :kind, :enabled]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:path, :label, :kind, :enabled]
    end

    update :record_check do
      accept [:accessible, :writable, :free_bytes]
      change set_attribute(:checked_at, &DateTime.utc_now/0)
    end

    read :enabled do
      filter expr(enabled == true)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :path, :string do
      allow_nil? false
      public? true
      description "The path as the container sees it, e.g. /tv1."
    end

    attribute :label, :string do
      public? true
      description "Optional human name, so the dashboard can say 'big-stinky' rather than /tv5."
    end

    attribute :kind, :atom do
      allow_nil? false
      default :any
      public? true
      constraints one_of: [:show, :movie, :any]
      description "Narrows which items may resolve here. :any suits a mixed root."
    end

    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true

    # Health, refreshed by a check rather than trusted from configuration. A
    # root that stopped resolving is the difference between "wrote nothing
    # because there was nothing to do" and "wrote nothing because the mount is
    # gone" -- the failure this whole layer exists to make visible.
    attribute :accessible, :boolean, allow_nil?: false, default: false, public?: true
    attribute :writable, :boolean, allow_nil?: false, default: false, public?: true
    attribute :free_bytes, :integer, public?: true
    attribute :checked_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_path, [:path]
  end
end
