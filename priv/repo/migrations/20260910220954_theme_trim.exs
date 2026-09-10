defmodule Fanfarr.Repo.Migrations.ThemeTrim do
  @moduledoc """
  Trim points for the written theme, on the item and in the application log.

  The two fade columns carry an explicit database-level default, which the
  generator does not emit: Ash applies resource defaults in the changeset, so
  as far as it is concerned the column needs none. SQLite disagrees --
  `ALTER TABLE ... ADD COLUMN ... NOT NULL` with no default is refused outright
  on a table that already has rows ("Cannot add a NOT NULL column with default
  value NULL"). Reproduced against a populated database before fixing: without
  these defaults every existing install fails this migration, and since the
  migrator runs ahead of the repo in the supervision tree, that is not a failed
  upgrade but a container that will not boot.
  """

  use Ecto.Migration

  def up do
    alter table(:theme_applications) do
      add :start_ms, :bigint
      add :end_ms, :bigint
    end

    alter table(:library_media_items) do
      add :theme_start_ms, :bigint
      add :theme_end_ms, :bigint
      add :theme_fade_in_ms, :bigint, null: false, default: 250
      add :theme_fade_out_ms, :bigint, null: false, default: 500
    end
  end

  def down do
    alter table(:library_media_items) do
      remove :theme_fade_out_ms
      remove :theme_fade_in_ms
      remove :theme_end_ms
      remove :theme_start_ms
    end

    alter table(:theme_applications) do
      remove :end_ms
      remove :start_ms
    end
  end
end
