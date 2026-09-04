defmodule Fanfarr.Themes.RemoverTest do
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Library
  alias Fanfarr.Themes.Remover

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-remove-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    section = Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "One Piece",
        kind: :show
      })

    %{item: item, dir: dir}
  end

  defp applied(item, dir) do
    path = Path.join(dir, "theme.mp3")
    File.write!(path, "audio")

    item =
      Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: path})

    Fanfarr.Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: :themerrdb,
      method: :local_file,
      destination_path: path,
      dry_run: false,
      status: :succeeded
    })

    {item, path}
  end

  test "deletes the file and clears the record", %{item: item, dir: dir} do
    {item, path} = applied(item, dir)

    assert {:ok, item} = Remover.remove(item)

    refute File.exists?(path)
    refute item.local_theme_present
    assert item.local_theme_path == nil
  end

  test "the item stops reporting fanfarr_applied", %{item: item, dir: dir} do
    {item, _path} = applied(item, dir)
    assert Ash.load!(item, :theme_status).theme_status == :fanfarr_applied

    {:ok, item} = Remover.remove(item)

    # Without the :removed row the log's latest entry would still be
    # :succeeded, and the item would claim a theme it no longer has.
    assert Ash.load!(item, :theme_status).theme_status == :missing
  end

  test "appends to the log rather than editing what is there", %{item: item, dir: dir} do
    {item, _path} = applied(item, dir)
    {:ok, item} = Remover.remove(item)

    history = Fanfarr.Themes.theme_history_for_item!(item.id)

    assert [%{status: :removed}, %{status: :succeeded}] = history
  end

  test "a file already gone still counts as removed", %{item: item, dir: dir} do
    {item, path} = applied(item, dir)
    File.rm!(path)

    assert {:ok, item} = Remover.remove(item)
    refute item.local_theme_present
  end

  test "an item with no recorded path is cleared without complaint", %{item: item} do
    item = Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: nil})

    assert {:ok, item} = Remover.remove(item)
    refute item.local_theme_present
  end

  test "a file that cannot be deleted leaves the record alone", %{item: item, dir: dir} do
    # A directory rather than a chmod, because the suite runs as root often
    # enough that permission bits are not a reliable way to make a delete
    # fail. File.rm/1 answers :eperm for a directory whoever you are.
    undeletable = Path.join(dir, "not-a-file")
    File.mkdir_p!(undeletable)

    item =
      Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: undeletable
      })

    assert {:error, _reason} = Remover.remove(item)

    # The database must not claim the theme is gone while it is still there
    # being served.
    assert File.exists?(undeletable)
    assert Library.get_media_item!(item.id).local_theme_present
  end
end
