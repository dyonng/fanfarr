defmodule Fanfarr.Workers.UndoThemeTest do
  @moduledoc """
  Putting back the file the last apply replaced -- and nothing older, and
  never an upload.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Library
  alias Fanfarr.Themes
  alias Fanfarr.Workers.UndoTheme

  setup do
    root = Path.join(System.tmp_dir!(), "fanfarr-undo-#{:erlang.unique_integer([:positive])}")
    media = Path.join([root, "tv", "One Piece (1999)"])
    File.mkdir_p!(media)
    on_exit(fn -> File.rm_rf(root) end)

    section =
      Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

    item =
      Library.sync_media_item_from_plex!(%{
        plex_rating_key: "rk-#{:erlang.unique_integer([:positive])}",
        section_id: section.id,
        title: "One Piece",
        kind: :show,
        plex_path: media
      })

    %{media: media, item: item}
  end

  test "restores the file the last apply replaced", %{media: media, item: item} do
    theme = Path.join(media, "theme.mp3")
    File.write!(theme, "the-mistake")

    Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: theme})

    # What Writer.place leaves behind when it overwrites.
    previous = Themes.Writer.previous(theme)
    File.write!(previous, "the-original")

    assert :ok = UndoTheme.perform(%Oban.Job{args: %{"media_item_id" => item.id}})

    assert File.read!(theme) == "the-original"
    refute File.exists?(previous)

    assert [%{status: :succeeded} | _] = Themes.theme_history_for_item!(item.id)
  end

  test "without a previous file it cancels instead of failing", %{media: media, item: item} do
    theme = Path.join(media, "theme.mp3")
    File.write!(theme, "only-version")

    Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: theme})

    assert {:cancel, :no_previous} =
             UndoTheme.perform(%Oban.Job{args: %{"media_item_id" => item.id}})

    assert File.read!(theme) == "only-version"
  end
end
