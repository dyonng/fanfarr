defmodule Fanfarr.Health do
  @moduledoc """
  The checks behind the System page -- Sonarr's "Health" panel, for this
  stack.

  Each check answers one question an operator would otherwise discover by
  watching a job fail: can we reach Plex, is yt-dlp present, are the root
  folders where we left them, do the paths Plex reports resolve to anything
  on our side of the mount. A check is `:ok`, a `:warning` (something will
  degrade), or an `:error` (something will not work), always with a message
  that says what to do about it.

  Checks are plain functions so they can be run individually and tested
  without the monitor.
  """

  @type level :: :ok | :warning | :error
  @type result :: %{
          id: atom(),
          name: String.t(),
          level: level(),
          message: String.t(),
          detail: String.t() | nil
        }

  # Same short-and-final options the settings page probe uses.
  @probe [retry: false, receive_timeout: 5_000, connect_options: [timeout: 5_000]]
  @path_sample 25

  @doc "Every check, in display order."
  @spec run_all() :: [result()]
  def run_all do
    [
      plex(),
      ytdlp(),
      ffmpeg(),
      root_folders(),
      local_assets(),
      path_resolution(),
      themerrdb(),
      database()
    ]
  end

  @doc "Plex configured and answering."
  def plex do
    case Fanfarr.Config.plex_config() do
      {:error, :plex_not_configured} ->
        result(
          :plex,
          "Plex",
          :error,
          "Not configured",
          "Set the server URL and token under Settings."
        )

      {:ok, config} ->
        case Fanfarr.Plex.Client.impl().server_info(Map.put(config, :req_options, @probe)) do
          {:ok, info} ->
            result(:plex, "Plex", :ok, "Connected to #{info.name}", "Plex #{info.version}")

          {:error, :unauthorized} ->
            result(
              :plex,
              "Plex",
              :error,
              "Token rejected",
              "Plex answered 401. Check the token under Settings."
            )

          {:error, reason} ->
            result(
              :plex,
              "Plex",
              :error,
              "Unreachable",
              "#{describe(reason)} -- from inside the container, at #{config.base_url}."
            )
        end
    end
  end

  @doc "yt-dlp present, and which version."
  def ytdlp do
    case Fanfarr.Themes.Downloader.impl().version() do
      {:ok, version} ->
        result(:ytdlp, "yt-dlp", :ok, "Installed", "yt-dlp #{version}")

      {:error, :not_installed} ->
        result(
          :ytdlp,
          "yt-dlp",
          :error,
          "Not installed",
          "Nothing can be downloaded. The image ships it at /usr/local/bin/yt-dlp; a mount may be shadowing it."
        )

      {:error, reason} ->
        result(:ytdlp, "yt-dlp", :error, "Not working", describe(reason))
    end
  end

  @doc "ffmpeg present, which is what normalises a downloaded theme's loudness."
  def ffmpeg do
    case Fanfarr.Themes.Normalizer.version() do
      {:ok, version} ->
        result(
          :ffmpeg,
          "ffmpeg",
          :ok,
          "Installed",
          "#{version} -- target #{Fanfarr.Themes.Normalizer.target()} LUFS"
        )

      {:error, :not_installed} ->
        result(
          :ffmpeg,
          "ffmpeg",
          :warning,
          "Not installed",
          "Themes will still be written, but at whatever level they were uploaded at, so some will be far louder than others."
        )

      {:error, reason} ->
        result(:ffmpeg, "ffmpeg", :warning, "Not working", describe(reason))
    end
  end

  @doc """
  Every enabled library set to read local assets.

  The check that would have saved an afternoon. A library with "Use local
  assets" off never reads a sidecar file beside the media, `theme.mp3`
  included, so Fanfarr can write a perfectly good theme into a perfectly
  correct folder and Plex will go on reporting none -- with the scanner and
  the agents both working exactly as designed. Nothing else in the app can
  compensate for it, and it is invisible until someone reads the library's
  settings.
  """
  def local_assets do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         sections when sections != [] <- Fanfarr.Library.list_sections!() do
      config = Map.put(config, :req_options, @probe)

      off =
        sections
        |> Enum.filter(& &1.enabled)
        |> Enum.filter(&(local_assets_off?(config, &1) == true))
        |> Enum.map(& &1.title)

      case off do
        [] ->
          result(:local_assets, "Local assets", :ok, "Libraries are reading local assets", nil)

        titles ->
          result(
            :local_assets,
            "Local assets",
            :error,
            "#{Enum.join(titles, ", ")} #{if length(titles) == 1, do: "has", else: "have"} \"Use local assets\" off",
            "Plex will not read theme.mp3 beside the media there. In Plex: the library → Edit → Advanced → Use local assets."
          )
      end
    else
      {:error, :plex_not_configured} ->
        result(:local_assets, "Local assets", :warning, "Plex is not configured", nil)

      [] ->
        result(:local_assets, "Local assets", :warning, "No libraries synced yet", nil)
    end
  end

  defp local_assets_off?(config, section) do
    case Fanfarr.Plex.Client.impl().raw(config, "/library/sections/#{section.plex_key}/prefs") do
      {:ok, body} ->
        body
        |> get_in(["MediaContainer", "Setting"])
        |> List.wrap()
        |> Enum.map(&%{id: &1["id"], label: &1["label"], value: &1["value"]})
        |> Fanfarr.Plex.ThemeCheck.local_assets_off?()

      # A library we cannot ask about is not a library we can accuse.
      {:error, _reason} ->
        nil
    end
  end

  @doc "Every enabled root folder accessible and writable, from a fresh look at the disk."
  def root_folders do
    folders = Fanfarr.Library.list_enabled_root_folders!()

    cond do
      folders == [] ->
        result(
          :root_folders,
          "Root folders",
          :warning,
          "None configured",
          "Themes will be written to the path Plex reports. Fine when both see the library identically; add root folders under Settings otherwise."
        )

      true ->
        bad =
          folders
          |> Enum.map(&{&1, File.dir?(&1.path), writable?(&1.path)})
          |> Enum.reject(fn {_f, ok, w} -> ok and w end)

        case bad do
          [] ->
            result(
              :root_folders,
              "Root folders",
              :ok,
              "#{length(folders)} accessible and writable",
              nil
            )

          bad ->
            detail =
              Enum.map_join(bad, "; ", fn
                {f, false, _} -> "#{f.path} is missing"
                {f, true, false} -> "#{f.path} is read-only"
              end)

            result(
              :root_folders,
              "Root folders",
              :error,
              "#{length(bad)} of #{length(folders)} unusable",
              detail
            )
        end
    end
  end

  @doc "A sample of Plex-reported paths, run through mappings, actually exist here."
  def path_resolution do
    items =
      Fanfarr.Library.list_media_items!()
      |> Enum.filter(&(is_binary(&1.plex_path) and &1.plex_path != ""))
      |> Enum.take(@path_sample)

    if items == [] do
      result(
        :paths,
        "Path resolution",
        :warning,
        "Nothing to check yet",
        "Sync the library first."
      )
    else
      mappings = Fanfarr.Config.path_mappings()

      roots = %{
        show: Fanfarr.Library.root_paths(:show),
        movie: Fanfarr.Library.root_paths(:movie)
      }

      unresolved =
        Enum.reject(items, fn item ->
          local = Fanfarr.PathMapping.to_local(item.plex_path, mappings)

          case Fanfarr.Library.RootFolders.resolve(local, roots[item.kind]) do
            {:ok, dir, _} -> File.dir?(dir)
            _ -> false
          end
        end)

      case unresolved do
        [] ->
          result(
            :paths,
            "Path resolution",
            :ok,
            "#{length(items)} of #{length(items)} sampled paths resolve",
            nil
          )

        bad ->
          example = hd(bad)

          result(
            :paths,
            "Path resolution",
            :error,
            "#{length(bad)} of #{length(items)} sampled paths do not resolve",
            "e.g. \"#{example.title}\" reports #{example.plex_path}, which does not exist here. Check the root folders and path mappings under Settings."
          )
      end
    end
  end

  @doc "ThemerrDB reachable."
  def themerrdb do
    case Fanfarr.Themes.ThemerrDB.reachable?() do
      :ok ->
        result(:themerrdb, "ThemerrDB", :ok, "Reachable", nil)

      {:error, reason} ->
        result(
          :themerrdb,
          "ThemerrDB",
          :warning,
          "Unreachable",
          "#{describe(reason)}. Lookups will retry; manual picks still work."
        )
    end
  end

  @doc "SQLite answering, in WAL mode."
  def database do
    case Fanfarr.Repo.query("PRAGMA journal_mode") do
      {:ok, %{rows: [["wal"]]}} ->
        result(:database, "Database", :ok, "OK", "SQLite, WAL mode")

      {:ok, %{rows: [[mode]]}} ->
        result(
          :database,
          "Database",
          :warning,
          "Not in WAL mode",
          "journal_mode is #{mode}; concurrent reads will block behind writes."
        )

      {:error, reason} ->
        result(:database, "Database", :error, "Query failed", describe(reason))
    end
  end

  @doc "The worst level among results, for the sidebar badge."
  @spec worst([result()]) :: level()
  def worst(results) do
    cond do
      Enum.any?(results, &(&1.level == :error)) -> :error
      Enum.any?(results, &(&1.level == :warning)) -> :warning
      true -> :ok
    end
  end

  defp writable?(dir) do
    probe = Path.join(dir, ".fanfarr-write-check")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      _ ->
        false
    end
  end

  defp result(id, name, level, message, detail),
    do: %{id: id, name: name, level: level, message: message, detail: detail}

  defp describe(%{reason: reason}), do: describe(reason)
  defp describe(:econnrefused), do: "connection refused"
  defp describe(:nxdomain), do: "host not found"
  defp describe(:timeout), do: "timed out"
  defp describe(:ehostunreach), do: "host unreachable"
  defp describe(other), do: inspect(other)
end
