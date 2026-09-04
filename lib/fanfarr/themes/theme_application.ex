defmodule Fanfarr.Themes.ThemeApplication do
  @moduledoc """
  An append-only record of every theme Fanfarr has applied, or tried to.

  This log exists because **theme uploads cannot be undone through Plex's API**.
  `deleteTheme()` raises, and uploaded themes accumulate in the server's data
  directory with no supported way to remove them. Anything we upload is
  permanent, so there has to be a durable record of what we did and why.

  Rows are never updated to reflect a later outcome, and nothing here deletes
  one. A retry is a new row. That is what makes the log answer "what has this
  server been sent, and when", which a mutable status column could not.

  Rows go only when the item itself does. A rename does not count: sync
  recognises the renamed item as the same one and keeps the row it always had
  (see `Fanfarr.Workers.SyncSection`), so the history follows the title rather
  than being stranded. An item genuinely removed from Plex is deleted, and the
  database takes its rows with it -- the log records what was done *to an
  item*, and the Activity page renders each row by its item's title, so rows
  pointing at nothing would be unreadable. That does mean a theme uploaded to
  Plex for an item later removed is still permanent on the Plex server with no
  record of it here.

  It also carries the idempotency check: before applying anything, look here.
  If the intended theme is already recorded as succeeded for this item, there
  is nothing to do, and re-uploading would grow the data directory for no gain.

  Dry runs are recorded too, with `dry_run: true`. They are excluded from every
  aggregate that feeds the dashboard, so previewing never changes what the
  library reports -- but keeping them means a preview can be inspected after
  the fact rather than only watched as it scrolls past.
  """
  use Ash.Resource,
    otp_app: :fanfarr,
    domain: Fanfarr.Themes,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "theme_applications"
    repo Fanfarr.Repo
  end

  actions do
    # No update: nothing rewrites a row once written.
    defaults [:read]
    default_accept :*

    # The only way a row goes, and it is not reachable from anywhere except a
    # media item being deleted -- MediaItem's destroy cascades through it. The
    # foreign key would otherwise refuse that delete outright, and SQLite
    # cannot be given an ON DELETE CASCADE after the fact without rebuilding
    # the table, which is not worth doing to someone's live database.
    destroy :destroy_with_item do
      primary? true
    end

    create :create do
      primary? true
      accept :*
    end

    # Written BEFORE the upload is attempted, so a crash mid-upload leaves
    # evidence that something was in flight rather than silence.
    create :record_intent do
      accept [:media_item_id, :source, :method, :theme_url, :destination_path, :dry_run]

      change set_attribute(:status, :pending)
      change set_attribute(:attempted_at, &DateTime.utc_now/0)
    end

    create :record_outcome do
      accept [
        :media_item_id,
        :source,
        :method,
        :theme_url,
        :destination_path,
        :dry_run,
        :status,
        :error,
        :codec,
        :bytes,
        :loudness_lufs
      ]

      change set_attribute(:attempted_at, &DateTime.utc_now/0)
    end

    read :for_item do
      argument :media_item_id, :uuid, allow_nil?: false
      filter expr(media_item_id == ^arg(:media_item_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :failures do
      filter expr(status == :failed and dry_run == false)
      prepare build(sort: [inserted_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:themerrdb, :youtube, :upload, :local]
      description "Where the theme came from."
    end

    attribute :method, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:api_upload, :local_file]

      description """
      How it was applied. :api_upload is irreversible through Plex's API;
      :local_file writes theme.mp3 beside the media and can simply be deleted.
      """
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :succeeded, :failed, :skipped, :removed]

      description """
      :skipped means the intended theme was already applied -- the idempotency
      path. :removed is the theme.mp3 being deleted again, recorded as its own
      row rather than by editing the apply's: the log is append-only, and
      `ThemeStatus` reads the latest row, so an item whose file has just been
      deleted would otherwise go on reporting :fanfarr_applied.
      """
    end

    attribute :theme_url, :string, public?: true

    attribute :destination_path, :string do
      public? true

      description "For :local_file, the resolved directory actually written to, after root folder resolution."
    end

    attribute :dry_run, :boolean do
      allow_nil? false
      default false
      public? true
      description "Previews are recorded but excluded from every dashboard aggregate."
    end

    attribute :error, :string, public?: true

    attribute :codec, :string do
      public? true
      description "Detected codec. Opus will not play on some clients, notably Apple TV."
    end

    attribute :bytes, :integer, public?: true

    attribute :loudness_lufs, :float do
      public? true

      description """
      Integrated loudness of the file that was written, in LUFS. Recorded so
      "is this theme in line with the others" is answerable from the log
      rather than by listening to them one after another.
      """
    end

    attribute :attempted_at, :utc_datetime_usec, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :media_item, Fanfarr.Library.MediaItem do
      allow_nil? false
      attribute_writable? true
      # Without this the generated foreign key stays private, so `accept :*`
      # silently excludes it and every create fails on a missing relationship.
      attribute_public? true
    end
  end
end
