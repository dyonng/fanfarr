defmodule Fanfarr.PlexThemes do
  @moduledoc """
  A disk cache of the theme audio Plex itself supplies.

  The item page can only preview what the browser can fetch, and the browser
  must never see a Plex URL: the token lives in it. So the server fetches the
  theme once, into a file under the config volume, and serves it from there
  like any static asset -- the same shape as `Fanfarr.Posters`, for audio.

  Keyed by the item's `plex_theme_url`, which changes when Plex's theme does,
  so a stale theme is a new key and a new file; old files are simply never
  requested again. A cache miss for an item whose fetch fails is not recorded,
  so it is retried on the next view rather than sticking.
  """

  require Logger

  @doc "Where cached Plex themes live. Under /config in the container so they survive restarts."
  def dir do
    Application.get_env(:fanfarr, :cache_dir, Path.join(System.tmp_dir!(), "fanfarr-cache"))
    |> Path.join("plex-themes")
  end

  @doc """
  The cached file for an item, fetching it from Plex if needed.

  Returns the path, or an error the controller turns into a 404. Never raises
  on a Plex failure: a missing preview is cosmetic.
  """
  @spec path_for(Fanfarr.Library.MediaItem.t()) :: {:ok, Path.t()} | {:error, term()}
  def path_for(%{plex_theme_url: url}) when url in [nil, ""], do: {:error, :no_plex_theme}

  def path_for(%{id: id, plex_theme_url: url}) do
    file = Path.join(dir(), "#{id}-#{digest(url)}")

    case existing(file) do
      {:ok, _path} = hit -> hit
      :miss -> fetch(file, url)
    end
  end

  # The extension records the content type, so serving needs no sidecar.
  defp existing(base) do
    Enum.find_value(["mp3", "m4a", "ogg", "opus", "flac", "wav"], :miss, fn ext ->
      path = "#{base}.#{ext}"
      if File.regular?(path), do: {:ok, path}
    end)
  end

  defp fetch(base, key) do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, {type, bytes}} <- Fanfarr.Plex.Client.impl().fetch_theme(config, key) do
      path = "#{base}.#{ext_of(type)}"
      File.mkdir_p!(Path.dirname(path))

      # Written beside its final name and renamed, so a crash mid-write does
      # not leave a truncated file that then serves forever as a "hit".
      tmp = "#{path}.part"

      with :ok <- File.write(tmp, bytes),
           :ok <- File.rename(tmp, path) do
        {:ok, path}
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.debug("[fanfarr] Plex theme fetch failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp digest(key),
    do: :crypto.hash(:sha, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp ext_of("audio/mp4"), do: "m4a"
  defp ext_of("audio/x-m4a"), do: "m4a"
  defp ext_of("audio/ogg"), do: "ogg"
  defp ext_of("audio/opus"), do: "opus"
  defp ext_of("audio/flac"), do: "flac"
  defp ext_of("audio/wav"), do: "wav"
  defp ext_of("audio/x-wav"), do: "wav"
  defp ext_of(_), do: "mp3"
end
