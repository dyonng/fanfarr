defmodule Fanfarr.Workers.UndoTheme do
  @moduledoc """
  Restores the theme the last apply replaced.

  Every write stashes the file it replaces (`Writer.previous/1`), so an undo
  puts back exactly what was there -- nothing older. Plex is then told the
  way a fresh apply would be: scan the folder, refresh the item, and select
  the restored file if Plex lists it unselected. No upload ever happens
  here: an upload cannot be undone through Plex's API, and an undo that
  uploaded would trade one irreversible state for another.

  When Plex is already serving something else (for instance an earlier
  upload), the bytes are still restored -- the file next to the media is
  correct -- and the outcome says so rather than pretending Plex followed.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Fanfarr.Library
  alias Fanfarr.Themes

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id}}) do
    item = Library.get_media_item!(item_id)

    with path when is_binary(path) and path != "" <- item.local_theme_path,
         previous <- Themes.Writer.previous(path),
         true <- File.regular?(previous) || {:error, :no_previous},
         :ok <- swap(previous, path) do
      item =
        Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: path})

      record(item, path)
      hand_over(item, path)
      :ok
    else
      {:error, reason} -> {:cancel, reason}
      _ -> {:cancel, :no_local_theme}
    end
  end

  # The restored file takes the theme's name; the file it replaces was already
  # superseded once, and keeping it would leave two live-looking files where
  # Plex scans. A cross-device move falls back to copy the way the writer does.
  defp swap(previous, path) do
    case File.rename(previous, path) do
      :ok ->
        :ok

      {:error, :exdev} ->
        with :ok <- File.cp(previous, path) do
          File.rm(previous)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record(item, path) do
    size =
      case File.stat(path) do
        {:ok, %{size: bytes}} -> bytes
        _ -> nil
      end

    Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: :local,
      method: :local_file,
      destination_path: path,
      status: :succeeded,
      bytes: size
    })

    Phoenix.PubSub.broadcast(Fanfarr.PubSub, "item:#{item.id}", {:item_updated, item.id})
  end

  # The same handshake an apply does, minus the upload: scan so Plex sees the
  # restored file, refresh so the agents run, select it when Plex lists it
  # without serving it. Whatever Plex ends up serving is recorded, because a
  # restore that claims more than Plex did is the same lie in reverse.
  defp hand_over(item, path) do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, _before, state} <-
           Fanfarr.Plex.ThemeCheck.refresh_and_reread(config, item.plex_rating_key, scan(item)),
         state = promote(config, item, path, state) do
      Library.record_plex_theme!(item, %{
        plex_theme_url: state[:url],
        plex_theme_origin: state[:origin],
        plex_theme_agent: state[:agent],
        theme_locked: "theme" in (state[:locked_fields] || [])
      })
    else
      _ -> :ok
    end
  end

  defp promote(_config, _item, _path, %{url: url} = state) when is_binary(url), do: state

  # The scan just ran, so a listed-but-unselected theme is the restored file
  # waiting to be picked up -- the same judgement an apply makes.
  defp promote(config, item, _path, %{listed_not_selected: true, themes: [theme | _]}) do
    case Fanfarr.Plex.ThemeCheck.select(config, item.plex_rating_key, theme.rating_key) do
      {:ok, selected} -> selected
      _ -> %{}
    end
  end

  defp promote(_config, _item, _path, _state), do: %{}

  defp scan(item) do
    section = Ash.load!(item, :section).section

    if is_binary(item.plex_path) and item.plex_path != "" and is_binary(section.plex_key) do
      {section.plex_key, item.plex_path}
    end
  end
end
