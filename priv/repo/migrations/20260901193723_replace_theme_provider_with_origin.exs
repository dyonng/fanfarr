defmodule Fanfarr.Repo.Migrations.ReplaceThemeProviderWithOrigin do
  @moduledoc """
  Replaces plex_theme_provider with a theme origin read from Plex's ratingKey.

  plex_theme_provider was written against a `provider` field that Plex does not
  actually send. A survey against a live server confirmed it: the theme element
  carries no provider at all, and the origin is encoded in the ratingKey scheme
  instead. Nothing ever wrote the column, so dropping it loses nothing -- it is
  removed rather than left behind, so the schema stops implying a fact we can
  answer.

  The generator emitted `plex_theme_origin` as NOT NULL with no default, which
  fails against any database that already has rows. The default is set here so
  existing items land on :none and are corrected by the next sync.
  """

  use Ecto.Migration

  def up do
    alter table(:library_media_items) do
      add :plex_theme_origin, :text, null: false, default: "none"
      add :plex_theme_agent, :text
      remove :plex_theme_provider
    end
  end

  def down do
    alter table(:library_media_items) do
      add :plex_theme_provider, :text
      remove :plex_theme_agent
      remove :plex_theme_origin
    end
  end
end
