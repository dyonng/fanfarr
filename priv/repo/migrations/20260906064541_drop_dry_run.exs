defmodule Fanfarr.Repo.Migrations.DropDryRun do
  @moduledoc """
  Drops `dry_run` from theme_applications, and the rows that carried it.

  The generator comments attribute removals out to avoid data loss, which is
  the right default and the wrong answer here: while the column exists, every
  query that reads this table has to remember to exclude previews, and the one
  that forgets reports a preview as a real theme.

  The DELETE has to come first, and it is not optional. Those rows record runs
  that deliberately wrote nothing -- but `theme_status` and the failures
  aggregate excluded them by filtering on this column, and those filters are
  gone with it. Dropping the column alone would silently promote every old
  preview into a real application: an item that was only ever dry-run would
  start reporting as themed, with no file on disk to match.
  """

  use Ecto.Migration

  def up do
    execute("DELETE FROM theme_applications WHERE dry_run = 1")

    alter table(:theme_applications) do
      remove :dry_run
    end
  end

  # The column comes back, but the rows do not: they are gone, and a preview
  # of a run that never happened is not worth reconstructing.
  def down do
    alter table(:theme_applications) do
      add :dry_run, :boolean, null: false, default: false
    end
  end
end
