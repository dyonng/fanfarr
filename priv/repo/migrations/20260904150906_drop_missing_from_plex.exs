defmodule Fanfarr.Repo.Migrations.DropMissingFromPlex do
  @moduledoc """
  Drops the soft-delete column added one release earlier.

  v0.1.38 hid items Plex had stopped listing by stamping them; they are now
  deleted outright, so nothing reads the column. The generator comments
  attribute removals out to avoid data loss -- uncommented deliberately, since
  what is lost is a timestamp that existed for a single release and that no
  code now looks at.
  """

  use Ecto.Migration

  def up do
    alter table(:library_media_items) do
      remove :missing_from_plex_at
    end
  end

  def down do
    alter table(:library_media_items) do
      add :missing_from_plex_at, :utc_datetime_usec
    end
  end
end
