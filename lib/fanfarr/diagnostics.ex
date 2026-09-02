defmodule Fanfarr.Diagnostics do
  @moduledoc """
  The tools behind the System page's debugging section.

  Each returns plain text meant to be copied straight into a bug report, and
  every one of them runs its output through `Fanfarr.Diagnostics.Redactor`
  before returning it. Assume anything here becomes public.

  These exist because the alternative to a person being able to answer "what
  does your server actually report for that show" is a round trip of guesses,
  and guessing about Plex's responses has already cost this project a fabricated
  field and a library-wide `:no_plex_path`.
  """

  alias Fanfarr.Diagnostics.Redactor
  alias Fanfarr.Library
  alias Fanfarr.Themes.Downloader

  @theme_filename "theme.mp3"

  @doc "Everything about this install that does not depend on Plex being up."
  @spec environment() :: String.t()
  def environment do
    plex = Fanfarr.Config.get("plex_url")

    """
    Fanfarr #{Fanfarr.Version.display()}
    Elixir #{System.version()} / OTP #{:erlang.system_info(:otp_release)}

    Plex URL        #{plex || "(not set)"}
    Plex token      #{if blank?(Fanfarr.Config.get("plex_token")), do: "(not set)", else: "set"}
    Authentication  #{if Fanfarr.Accounts.AuthMode.required?(), do: "login required", else: "open"}
    Database        #{Fanfarr.Repo.config()[:database]}
    Cache           #{Fanfarr.Posters.dir()}
    Path mappings   #{Fanfarr.Config.get("path_mappings") || "(none)"}
    yt-dlp          #{ytdlp_version()}

    Libraries
    #{sections()}
    Root folders
    #{root_folders()}
    Counts
      items           #{length(Library.list_media_items!())}
      theme records   #{length(Fanfarr.Themes.list_theme_applications!())}
      ThemerrDB rows  #{length(Fanfarr.Themes.list_themerr_entries!())}
    """
    |> Redactor.redact()
  end

  @doc """
  Everything about one item, including why a theme could not be written for it.

  This is the report that answers `:no_plex_path` and its relatives: what Plex
  said, what the mapping made of it, which root folder it resolved to, and
  whether that directory exists and can be written to.
  """
  @spec item_report(String.t()) :: String.t()
  def item_report(item_id) do
    item = Library.get_media_item!(item_id, load: [:theme_status])

    """
    #{item.title} (#{item.year}) -- #{item.kind}
      id             #{item.id}
      ratingKey      #{item.plex_rating_key}
      status         #{item.theme_status}
      IDs            #{ids(item)}

    Theme
      Plex reports   #{item.plex_theme_url || "(none)"}
      origin         #{item.plex_theme_origin}#{agent(item)}
      locked         #{item.theme_locked}
      local file     #{item.local_theme_present} #{item.local_theme_path || ""}
      your pick      #{item.manual_theme_url || "(none)"}

    Path resolution
    #{path_trace(item)}
    History
    #{history(item)}
    """
    |> Redactor.redact()
  end

  @doc """
  A raw GET against the configured Plex server.

  The path is relative to the server's own base URL, so this can only reach
  the operator's Plex. Useful paths: `/library/sections`,
  `/library/sections/2/all`, `/library/metadata/45870`.
  """
  @spec plex_probe(String.t()) :: String.t()
  def plex_probe(path) do
    path = String.trim(path)

    cond do
      path == "" ->
        "Enter a path, e.g. /library/sections"

      not String.starts_with?(path, "/") ->
        "Paths are relative to the Plex server and must start with a slash."

      true ->
        case Fanfarr.Config.plex_config() do
          {:error, :plex_not_configured} ->
            "Plex is not configured."

          {:ok, config} ->
            case Fanfarr.Plex.Client.impl().raw(config, path) do
              {:ok, body} -> "GET #{path}\n\n#{pretty(body)}"
              {:error, reason} -> "GET #{path}\n\nFailed: #{inspect(reason)}"
            end
        end
    end
    |> Redactor.redact()
  end

  @doc """
  Whether yt-dlp can actually download a video.

  Answers the question an unplayable preview raises: a video that refuses to
  embed has usually had embedding disabled, which does not stop a download.
  """
  @spec video_probe(String.t()) :: String.t()
  def video_probe(url) do
    url = String.trim(url)

    cond do
      url == "" ->
        "Paste a YouTube URL."

      not Downloader.youtube_url?(url) ->
        "Not a YouTube URL, so it would be refused before any download."

      true ->
        case Downloader.impl().probe(url) do
          {:ok, info} ->
            """
            Downloadable: YES

              title     #{info.title}
              uploader  #{info.uploader || "(unknown)"}
              duration  #{format_duration(info.duration)}

            If this video will not play in the preview above, embedding is
            disabled for it. That is a restriction on the player, not on the
            download, and applying it will still work.
            """

          {:error, reason} ->
            "Downloadable: NO\n\n  #{explain(reason)}"
        end
    end
    |> Redactor.redact()
  end

  @doc "Environment, health and recent logs in one block, for a bug report."
  @spec bundle() :: String.t()
  def bundle do
    """
    ===== Fanfarr diagnostics =====
    Generated #{DateTime.utc_now() |> DateTime.truncate(:second)}

    ----- Environment -----
    #{environment()}
    ----- Health -----
    #{health()}
    ----- Recent log -----
    #{log_text(Fanfarr.Log.Buffer.entries(limit: 100))}
    """
    |> Redactor.redact()
  end

  @doc "Log entries rendered as plain text, newest last so it reads like a log."
  @spec log_text([Fanfarr.Log.Buffer.entry()]) :: String.t()
  def log_text([]), do: "(nothing captured yet)"

  def log_text(entries) do
    entries
    |> Enum.reverse()
    |> Enum.map_join("\n", fn e ->
      "#{Calendar.strftime(e.at, "%H:%M:%S")} [#{e.level}] #{e.message}"
    end)
  end

  # --- helpers ----------------------------------------------------------------

  defp health do
    case Fanfarr.Health.Monitor.latest() do
      %{results: results, at: at} ->
        "Checked #{DateTime.truncate(at, :second)}\n" <>
          Enum.map_join(results, "\n", fn r ->
            "  [#{r.level}] #{r.name}: #{r.message}#{if r.detail, do: " -- #{r.detail}", else: ""}"
          end)

      _ ->
        "(no health snapshot yet)"
    end
  end

  defp path_trace(%{plex_path: path}) when path in [nil, ""] do
    """
      Plex reported no path for this item, so there is nowhere to write a
      theme. Sync again: paths missing from the section listing are now
      fetched per item. If it stays empty, use the Plex probe above on
      /library/metadata/<ratingKey> and send the output.
    """
  end

  defp path_trace(item) do
    mappings = Fanfarr.Config.path_mappings()
    local = Fanfarr.PathMapping.to_local(item.plex_path, mappings)
    roots = Library.root_paths(item.kind)

    resolved =
      case Fanfarr.Library.RootFolders.resolve(local, roots) do
        {:ok, dir, how} -> "#{dir}  (#{how})"
        {:error, reason} -> "unresolved: #{inspect(reason)}"
      end

    # The same call the worker makes, so this cannot report "would write here"
    # about a destination the worker would refuse.
    verdict = Fanfarr.Workers.ApplyTheme.destination_dir(item)
    target = with {:ok, dir} <- verdict, do: dir, else: (_ -> nil)

    """
      Plex says      #{item.plex_path}
      after mapping  #{local}#{if local == item.plex_path, do: "  (unchanged)", else: ""}
      exists here    #{File.dir?(local)}#{host_path_note(local, verdict)}
      root folders   #{if roots == [], do: "(none configured)", else: Enum.join(roots, ", ")}
      resolves to    #{resolved}
      writable       #{writable(target)}
      would write    #{if target, do: Path.join(target, @theme_filename), else: "(nowhere)"}

      verdict        #{verdict_line(verdict)}
      same folder    #{same_folder(item, target)}
    """
  end

  # Root folders are matched by directory *name*, so with five drives mounted
  # a show called "One Pace" on tv2 and an unrelated "One Pace" on tv4 look
  # identical to the resolver. Writing to the wrong one succeeds, reports
  # success, and Plex never plays the theme -- with nothing anywhere saying
  # why. So the resolved directory is checked against a file Plex actually
  # reports for this item.
  defp same_folder(_item, nil), do: "n/a"

  defp same_folder(item, dir) do
    case plex_filenames(item) do
      {:ok, []} ->
        "unknown (Plex reported no files for this item)"

      {:ok, names} ->
        local = local_filenames(dir)

        if Enum.any?(names, &MapSet.member?(local, &1)) do
          "yes -- #{dir} holds files Plex reports for this item"
        else
          "NO -- #{dir} does not contain any file Plex reports for this item. " <>
            "Another drive probably has a folder of the same name; a theme written " <>
            "here will never be seen. Example Plex file: #{List.first(names)}"
        end

      {:error, reason} ->
        "unknown (#{inspect(reason)})"
    end
  end

  defp plex_filenames(item) do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, body} <-
           Fanfarr.Plex.Client.impl().raw(
             config,
             "/library/metadata/#{item.plex_rating_key}/allLeaves" <>
               "?X-Plex-Container-Start=0&X-Plex-Container-Size=3"
           ) do
      names =
        body
        |> Map.get("MediaContainer", %{})
        |> then(&(Map.get(&1, "Metadata", []) ++ Map.get(&1, "Video", [])))
        |> Enum.flat_map(&Map.get(&1, "Media", []))
        |> Enum.flat_map(&Map.get(&1, "Part", []))
        |> Enum.map(& &1["file"])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.basename/1)

      {:ok, names}
    end
  end

  # One level down as well, since episodes usually sit in season folders.
  defp local_filenames(dir) do
    [Path.join(dir, "*"), Path.join([dir, "*", "*"])]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&Path.basename/1)
    |> MapSet.new()
  end

  # Plex runs on the host and reports host paths; the container mounts the same
  # drives under whatever names the operator chose. So a reported path that
  # does not exist here is the normal case, not the fault -- root folders are
  # what bridge it, and saying so stops this line reading as the problem.
  defp host_path_note(_local, {:ok, _dir}), do: "  (expected: root folders bridge this)"
  defp host_path_note(_local, _error), do: ""

  defp verdict_line({:ok, dir}), do: "ready -- a theme would be written under #{dir}"

  defp verdict_line({:error, :no_plex_path}),
    do: "blocked -- Plex reported no path for this item"

  defp verdict_line({:error, {:no_matching_root, path}}),
    do:
      "blocked -- no root folder contains a directory named " <>
        "#{inspect(Path.basename(path))}. Add the drive that holds it under Settings."

  defp verdict_line({:error, {:destination_missing, dir}}),
    do:
      "blocked -- #{dir} does not exist in this container. Add root folders for " <>
        "the drives your libraries are mounted at, or add a path mapping."

  defp verdict_line({:error, reason}), do: "blocked -- #{inspect(reason)}"

  defp writable(nil), do: "n/a"

  defp writable(dir) do
    probe = Path.join(dir, ".fanfarr-write-check")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        "yes"

      {:error, reason} ->
        "no (#{inspect(reason)})"
    end
  end

  defp history(item) do
    case Fanfarr.Themes.theme_history_for_item!(item.id) do
      [] ->
        "  (no attempts)"

      entries ->
        entries
        |> Enum.take(10)
        |> Enum.map_join("\n", fn e ->
          "  #{Calendar.strftime(e.attempted_at, "%Y-%m-%d %H:%M")} #{e.status}" <>
            "#{if e.dry_run, do: " (dry run)", else: ""} #{e.source} #{e.error || ""}"
        end)
    end
  end

  defp sections do
    case Library.list_sections!() do
      [] ->
        "  (none synced)\n"

      sections ->
        Enum.map_join(sections, "\n", fn s ->
          "  #{s.title} (#{s.kind}, key #{s.plex_key}) #{if s.enabled, do: "enabled", else: "disabled"}"
        end) <> "\n"
    end
  end

  defp root_folders do
    case Library.list_root_folders!() do
      [] ->
        "  (none configured)\n"

      folders ->
        Enum.map_join(folders, "\n", fn f ->
          "  #{f.path} (#{f.kind}) accessible=#{f.accessible} writable=#{f.writable}"
        end) <> "\n"
    end
  end

  defp ytdlp_version do
    case Downloader.impl().version() do
      {:ok, version} -> version
      {:error, reason} -> "unavailable (#{inspect(reason)})"
    end
  end

  defp ids(item) do
    [
      item.imdb_id && "imdb:#{item.imdb_id}",
      item.tmdb_id && "tmdb:#{item.tmdb_id}",
      item.tvdb_id && "tvdb:#{item.tvdb_id}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> then(&if &1 == "", do: "(none)", else: &1)
  end

  defp agent(%{plex_theme_agent: nil}), do: ""
  defp agent(%{plex_theme_agent: agent}), do: " (#{agent})"

  defp pretty(body) do
    Jason.encode!(body, pretty: true)
  rescue
    _ -> inspect(body, pretty: true, limit: 200)
  end

  defp format_duration(nil), do: "(unknown)"

  defp format_duration(seconds) do
    total = trunc(seconds)
    "#{div(total, 60)}m #{rem(total, 60)}s"
  end

  defp explain(:not_installed), do: "yt-dlp is not installed in this container."
  defp explain(:unsupported_url), do: "Not a YouTube URL."
  defp explain(:unavailable), do: "The video is private, removed, or does not exist."
  defp explain(:age_restricted), do: "Age-restricted: YouTube requires a signed-in account."
  defp explain(:geo_blocked), do: "Blocked in this server's region."
  defp explain(:timeout), do: "YouTube did not answer in time."
  defp explain({:exit, _code, output}), do: "yt-dlp failed: #{output}"
  defp explain(other), do: inspect(other)

  defp blank?(value), do: value in [nil, ""]
end
