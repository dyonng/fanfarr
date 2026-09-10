defmodule Fanfarr.Themes.EditSource do
  @moduledoc """
  Finds something for the trim editor to scrub, in order of preference.

  The editor needs audio and a waveform. There are three places to get them,
  and the ladder exists so that the common cases cost nothing:

    1. **A cached original.** Someone edited this URL recently. Instant, and
       the best audio there is.

    2. **The theme already on disk**, when it was written whole. An applied
       theme with no crop is a faithful -- if lossy and loudness-normalised --
       rendering of the whole source, which is enough to choose a range
       against. Copied into the cache as a `:render` so the waveform is
       computed once, and so it is never mistaken for something to render a
       written theme from.

    3. **A fresh download** of the original stream, into the cache.

  ## Why rung 2 is derived and not flagged

  "Is the file on disk a whole-track render of the current pick?" is not
  stored anywhere. It is read from the application log: the last successful
  application for this item, its URL, and the crop it wrote. A boolean on the
  item would be a fourth fact that eventually disagrees with the log, the file
  and the pick -- the same reason `theme_status` is a calculation.

  A **cropped** theme can never serve as an edit source. The audio outside the
  crop is gone, so widening would be impossible and the editor would silently
  offer a range it could not honour. That case falls through to rung 3.
  """

  require Ash.Query
  require Logger

  alias Fanfarr.Themes
  alias Fanfarr.Themes.SourceCache

  @type resolved :: %{
          kind: SourceCache.kind(),
          peaks: Path.t(),
          path: Path.t(),
          url: String.t()
        }

  @doc """
  Audio and peaks for editing this item's theme.

  `:download` in the return says a fetch happened, so the caller can say so
  rather than appearing to hang for the seconds yt-dlp takes.
  """
  @spec resolve(Fanfarr.Library.MediaItem.t()) ::
          {:ok, resolved()} | {:error, :no_theme_url | term()}
  def resolve(item) do
    with {:ok, url, _source} <- Themes.Choice.url(item) do
      case SourceCache.fetch(url) do
        {:ok, entry} -> {:ok, Map.put(entry, :url, url)}
        :miss -> seed(item, url)
      end
    else
      {:error, :no_themerrdb_entry} -> {:error, :no_theme_url}
      other -> other
    end
  end

  defp seed(item, url) do
    case reusable_render(item, url) do
      {:ok, path} ->
        # Copied, not moved: that file is the operator's theme, sitting next to
        # their media.
        with {:ok, entry} <- cache_copy(url, path, :render) do
          {:ok, Map.put(entry, :url, url)}
        end

      :no ->
        download(url)
    end
  end

  defp download(url) do
    tmp = Path.join(System.tmp_dir!(), "fanfarr-edit-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      case Themes.Downloader.impl().download_source(url, tmp) do
        {:ok, %{path: path}} ->
          with {:ok, entry} <- SourceCache.put(url, path, :source) do
            {:ok, Map.put(entry, :url, url)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm_rf(tmp)
    end
  end

  # SourceCache.put/3 moves what it is given, so a file we do not own is
  # staged through a scratch copy first.
  defp cache_copy(url, path, kind) do
    tmp = Path.join(System.tmp_dir!(), "fanfarr-edit-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      staged = Path.join(tmp, "source" <> Path.extname(path))

      case File.cp(path, staged) do
        :ok -> SourceCache.put(url, staged, kind)
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm_rf(tmp)
    end
  end

  @doc """
  The written theme, when it is a whole-track render of `url`.

  Public because the item page asks the same question to decide whether
  opening the editor will need a download.
  """
  @spec reusable_render(Fanfarr.Library.MediaItem.t(), String.t()) :: {:ok, Path.t()} | :no
  def reusable_render(item, url) do
    with true <- item.local_theme_present,
         path when is_binary(path) <- item.local_theme_path,
         true <- File.regular?(path),
         %{theme_url: ^url, start_ms: nil, end_ms: nil} <- last_success(item.id) do
      {:ok, path}
    else
      _ -> :no
    end
  end

  defp last_success(item_id) do
    Themes.ThemeApplication
    |> Ash.Query.filter(media_item_id == ^item_id and status == :succeeded)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end
end
