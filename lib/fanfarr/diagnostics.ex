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

    target =
      case Fanfarr.Library.RootFolders.resolve(local, roots) do
        {:ok, dir, _} -> dir
        _ -> nil
      end

    """
      Plex says      #{item.plex_path}
      after mapping  #{local}#{if local == item.plex_path, do: "  (unchanged)", else: ""}
      exists here    #{File.dir?(local)}
      root folders   #{if roots == [], do: "(none configured)", else: Enum.join(roots, ", ")}
      resolves to    #{resolved}
      writable       #{writable(target)}
      would write    #{if target, do: Path.join(target, "theme.mp3"), else: "(nowhere)"}
    """
  end

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
