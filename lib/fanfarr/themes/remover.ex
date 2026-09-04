defmodule Fanfarr.Themes.Remover do
  @moduledoc """
  Deletes a theme Fanfarr wrote, and records that it did.

  The local-file route was chosen over Plex's upload API precisely because it
  is reversible -- "delete the file and it is undone" is the reason this
  project writes `theme.mp3` beside the media at all. Until this existed that
  undo needed a shell on the box, which left the product claiming a property
  its UI would not let you use.

  ## Order, and why the record is written last

  The file is deleted first and the record cleared only if that succeeded. The
  other order would be worse in the one case that matters: a read-only mount
  or a permission error would leave the database saying there is no theme
  while the file is still sitting beside the media, still being served. A
  removal that failed has to keep saying so.

  ## Removal is a new row, not an edit

  `Fanfarr.Themes.ThemeApplication` is append-only, so this appends a
  `:removed` row rather than touching the `:succeeded` one. That is also what
  keeps the status honest: `Fanfarr.Library.MediaItem.ThemeStatus` reads the
  latest non-dry-run row, so without this the item would keep reporting
  `:fanfarr_applied` after its file was gone.

  ## What it deliberately does not do

  It does not reach into Plex. Anything Fanfarr *uploaded* through the API is
  Plex's own copy and cannot be deleted through it -- that is the whole reason
  uploads are the last resort. Deleting the local file and letting the
  operator re-read Plex is the most that can honestly be offered here.
  """

  require Logger

  alias Fanfarr.Library

  @doc """
  Deletes the item's local theme file and clears the record of it.

  A file that has already gone counts as removed: the point is that there is
  no theme.mp3 afterwards, not that this call is what unlinked it.
  """
  @spec remove(Library.MediaItem.t()) :: {:ok, Library.MediaItem.t()} | {:error, term()}
  def remove(item) do
    path = item.local_theme_path

    case delete(path) do
      :ok ->
        item =
          Library.record_local_theme!(item, %{
            local_theme_present: false,
            local_theme_path: nil
          })

        record_removal(item, path)
        Logger.info("[fanfarr] removed the theme at #{path || "(no path recorded)"}")
        {:ok, item}

      {:error, reason} ->
        Logger.warning("[fanfarr] could not remove #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Nothing recorded to delete. The row still needs clearing -- this is the
  # shape an item takes when the file was removed by hand and the scan noticed.
  defp delete(path) when path in [nil, ""], do: :ok

  defp delete(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_removal(item, path) do
    Fanfarr.Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: :local,
      method: :local_file,
      destination_path: path,
      dry_run: false,
      status: :removed
    })
  end
end
