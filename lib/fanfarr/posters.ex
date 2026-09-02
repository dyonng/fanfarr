defmodule Fanfarr.Posters do
  @moduledoc """
  A disk cache of Plex artwork.

  The dashboard lists a few thousand titles and Plex serves posters slowly and
  with a token in the URL. Both problems go away if each poster is fetched
  once, by the server, into a file under the config volume, and then served
  from there like any static asset -- so the browser never sees a Plex URL,
  and a page of fifty rows costs zero Plex requests after the first time.

  Keyed by the item's `plex_thumb_key`, which Plex changes when the art
  changes, so a stale poster is a new key and a new file; old files are simply
  never requested again. A cache miss for an item whose fetch fails is not
  recorded, so it is retried on the next view rather than sticking.
  """

  require Logger

  @doc "Where cached posters live. Under /config in the container so they survive restarts."
  def dir do
    Application.get_env(:fanfarr, :cache_dir, Path.join(System.tmp_dir!(), "fanfarr-cache"))
    |> Path.join("posters")
  end

  @doc """
  The cached file for an item, fetching it from Plex if needed.

  Returns the path and content type, or an error the controller turns into a
  placeholder. Never raises on a Plex failure: a missing poster is cosmetic.
  """
  @spec path_for(Fanfarr.Library.MediaItem.t()) ::
          {:ok, Path.t(), String.t()} | {:error, term()}
  def path_for(%{plex_thumb_key: key}) when key in [nil, ""], do: {:error, :no_thumb}

  def path_for(%{id: id, plex_thumb_key: key}) do
    file = Path.join(dir(), "#{id}-#{digest(key)}")

    case existing(file) do
      {:ok, _path, _type} = hit -> hit
      :miss -> fetch(file, key)
    end
  end

  # The extension records the content type, so serving needs no sidecar.
  defp existing(base) do
    Enum.find_value(["jpg", "png", "webp"], :miss, fn ext ->
      path = "#{base}.#{ext}"
      if File.regular?(path), do: {:ok, path, type_of(ext)}
    end)
  end

  defp fetch(base, key) do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, {type, bytes}} <- Fanfarr.Plex.Client.impl().fetch_image(config, key, []) do
      path = "#{base}.#{ext_of(type)}"
      File.mkdir_p!(Path.dirname(path))

      # Written beside its final name and renamed, so a crash mid-write does
      # not leave a truncated image that then serves forever as a "hit".
      tmp = "#{path}.part"

      with :ok <- File.write(tmp, bytes),
           :ok <- File.rename(tmp, path) do
        {:ok, path, type_of(ext_of(type))}
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.debug("[fanfarr] poster fetch failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp digest(key),
    do: :crypto.hash(:sha, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp ext_of("image/png"), do: "png"
  defp ext_of("image/webp"), do: "webp"
  defp ext_of(_), do: "jpg"

  defp type_of("png"), do: "image/png"
  defp type_of("webp"), do: "image/webp"
  defp type_of(_), do: "image/jpeg"
end
