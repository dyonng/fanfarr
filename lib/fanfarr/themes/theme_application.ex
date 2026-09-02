defmodule Fanfarr.Themes.ThemeApplication do
  @moduledoc """
  An append-only record of every theme Fanfarr has applied, or tried to.

  This log exists because **theme uploads cannot be undone through Plex's API**.
  `deleteTheme()` raises, and uploaded themes accumulate in the server's data
  directory with no supported way to remove them. Anything we upload is
  permanent, so there has to be a durable record of what we did and why.

  Rows are never updated to reflect a later outcome and never deleted. A retry
  is a new row. That is what makes the log answer "what has this server been
  sent, and when", which a mutable status column could not.

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
    # No update, and destroy is absent by design: the log is append-only.
    defaults [:read]
    default_accept :*

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
      constraints one_of: [:pending, :succeeded, :failed, :skipped]
      description ":skipped means the intended theme was already applied -- the idempotency path."
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
