defmodule Fanfarr.Workers.ApplyTheme do
  @moduledoc """
  Resolve a theme for one item and put it on disk.

  ## Only local theme files, for now

  A theme.mp3 beside the media is reversible: deleting the file undoes it.
  Uploading through the Plex API is not, and the project's first rule is that
  irreversible actions need more care than this worker currently takes. Local
  files are also the well-established path for **TV shows**, which is the use
  case this exists for.

  Movies go through the same path, and it works: verified against a live
  server, Plex picks up a local theme.mp3 for a movie exactly as it does for a
  show. Its movie agent supplies no themes of its own, which is the gap this
  project exists to fill, but Local Media Assets reads one we put there.

  What movies do need is a folder of their own. A show's path is a directory
  by construction; a movie's is derived from its media file, so a film sitting
  loose among others yields the shared folder, and a theme written there would
  attach to everything in it. `destination_dir/1` refuses that case rather
  than writing.

  ## Cropping on the way in

  A theme that arrives long enough to be worth shortening is shortened here, in
  the same pass, using the window `AutoCrop` places in the audio that just
  landed. The operator's own crop always wins, and a theme below the configured
  floor is written whole: the floor is the unattended rule, and this is the
  unattended path. Cropping here rather than queueing the trimmer keeps the cut
  before normalisation, which is what keeps a cropped theme level-matched with
  the rest of the library.

  ## Ordering

  The intent row is written before anything happens, so a crash mid-flight
  leaves evidence rather than silence. No database transaction spans the
  download.
  """
  # Keyed on the URL as well as the item: applying a ThemerrDB suggestion and
  # then a URL picked from search are two different jobs for the same item,
  # and the second must not be swallowed as a duplicate of the first. The force
  # flag is in there for the same reason -- a redownload is a different job
  # from an apply that would be happy with the cached source.
  use Oban.Worker,
    queue: :apply,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:media_item_id, :theme_url, :force_download],
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Themes

  @theme_filename "theme.mp3"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id} = args}) do
    item = Library.get_media_item!(item_id)

    case plan(item, args) do
      {:ok, plan} ->
        record_intent(item, plan)
        execute(item, plan)

      {:error, reason} ->
        # A plan that cannot be made is a permanent condition -- a locked item,
        # an unmapped path, no ThemerrDB entry. Retrying does not help.
        record_outcome(item, blank_plan(), :skipped, reason)
        {:cancel, reason}
    end
  end

  @doc """
  Queues this worker for an item.

  `:theme_url` applies that URL instead of the item's manual pick or ThemerrDB
  entry -- used by "apply this one" from a search result, where the URL was
  just listened to. `force: true` fetches the source again instead of using the
  cached copy, which is what the item page's Redownload does.
  """
  @spec enqueue(Fanfarr.Library.MediaItem.t() | String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(item_or_id, opts \\ []) do
    id = if is_binary(item_or_id), do: item_or_id, else: item_or_id.id

    %{media_item_id: id}
    |> maybe_put(:theme_url, opts[:theme_url])
    |> maybe_put(:source, opts[:source])
    |> maybe_put(:force_download, opts[:force])
    |> new()
    |> Oban.insert()
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # --- planning ---------------------------------------------------------------

  defp plan(item, args) do
    with :ok <- check_eligible(item),
         {:ok, url, source} <- theme_url(item, args),
         {:ok, dir} <- destination_dir(item) do
      {:ok,
       %{
         url: url,
         source: source,
         dir: dir,
         path: Path.join(dir, @theme_filename),
         trim: trim(item),
         force: args["force_download"] == true
       }}
    end
  end

  # Read off the item rather than passed in the job args: the trim is a
  # property of the pick, and a job queued before an edit should write what the
  # item says now. The alternative -- baking it into the args -- means a queued
  # bulk apply carries a stale crop for however long the queue is deep.
  defp trim(item) do
    %{
      start_ms: item.theme_start_ms,
      end_ms: item.theme_end_ms,
      fade_in_ms: item.theme_fade_in_ms,
      fade_out_ms: item.theme_fade_out_ms
    }
  end

  defp shared_root?(dir, roots) do
    target = Path.expand(dir)
    Enum.any?(roots, &(Path.expand(&1) == target))
  end

  defp check_eligible(%{theme_locked: true}), do: {:error, :theme_locked}

  defp check_eligible(_item), do: :ok

  # Precedence lives in Fanfarr.Themes.Choice, shared with the library table.
  # The table says ahead of time whether pressing Apply will do anything, and
  # it can only do that honestly if both read the same rule.
  defp theme_url(item, args), do: Fanfarr.Themes.Choice.url(item, args)

  @doc """
  The directory a theme for this item would be written to, or why not.

  Public so the System page's item trace reports the same answer the worker
  acts on. A diagnostic that can disagree with the code it is diagnosing is
  worse than no diagnostic.
  """
  @spec destination_dir(Fanfarr.Library.MediaItem.t()) ::
          {:ok, String.t()} | {:error, term()}
  def destination_dir(%{plex_path: nil}), do: {:error, :no_plex_path}
  def destination_dir(%{plex_path: ""}), do: {:error, :no_plex_path}

  # The order here is the whole point of root folders, and an earlier version
  # had it backwards: it checked that the path Plex reported existed inside
  # this container and gave up when it did not.
  #
  # It usually does not. Plex runs on the host and reports host paths like
  # /media/red-10-redemption/TV/One Pace; the container mounts the same drives
  # wherever the operator chose, as /tv1../tv5. Root folders exist precisely to
  # bridge that, by matching the item's directory name across them. Demanding
  # that the reported path resolve first rejected every item the mechanism was
  # built to handle.
  #
  # So: resolve first, then check the directory we would actually write to.
  def destination_dir(item) do
    # to_local/2 returns the path unchanged when nothing matches, because the
    # common case is that Plex and Fanfarr see the library identically.
    local = Fanfarr.PathMapping.to_local(item.plex_path, Fanfarr.Config.path_mappings())
    roots = Library.root_paths(item.kind)

    case Fanfarr.Library.RootFolders.resolve(local, roots) do
      {:ok, dir, how} ->
        warn_if_ambiguous(item, dir, how)

        cond do
          not File.dir?(dir) ->
            {:error, {:destination_missing, dir}}

          # A movie's directory is derived from its media file, so a film
          # sitting loose in a library root resolves to the root itself. A
          # theme written there is not this movie's theme, it is every
          # neighbouring file's, so it is refused rather than written.
          shared_root?(dir, roots) ->
            {:error, {:not_in_own_folder, dir}}

          true ->
            {:ok, dir}
        end

      {:error, :not_found} ->
        {:error, {:no_matching_root, local}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Several roots hold a directory of this name and the tiebreaks did not
  # separate them. A directory is still returned and writing to it is better
  # than refusing, but it is worth saying out loud.
  defp warn_if_ambiguous(item, dir, :ambiguous) do
    Logger.warning(
      "[fanfarr] #{item.title}: several root folders hold a directory by that " <>
        "name; writing to #{dir}"
    )
  end

  defp warn_if_ambiguous(_item, _dir, _how), do: :ok

  # --- execution --------------------------------------------------------------

  defp execute(item, plan) do
    with :ok <- writable?(plan.dir),
         {:ok, download} <- download(plan) do
      # The local theme is recorded first: record_outcome broadcasts, and a
      # subscriber that reloads before this ran would see the previous file's
      # timestamp -- which is what left the audio player on the item page
      # playing the old theme until the page was refreshed by hand.
      item =
        Library.record_local_theme!(item, %{
          local_theme_present: true,
          local_theme_path: plan.path
        })

      # Before record_outcome, which broadcasts: a subscriber that reloads
      # after it should see the crop the file actually has.
      item = record_auto_trim(item, download)

      record_outcome(item, plan, :succeeded, nil, download)
      hand_over_to_plex(item, plan)
      :ok
    else
      {:error, reason} ->
        record_outcome(item, plan, :failed, reason)
        retry_or_stop(reason)
    end
  end

  # The automatic crop is written to the item as well as to the file, so the
  # item page shows the range the theme really has, and so a later trim
  # recognises the file as cropped rather than cutting a second generation.
  defp record_auto_trim(item, %{auto_trim: trim}) do
    Library.set_theme_trim!(item, %{
      theme_start_ms: trim.start_ms,
      theme_end_ms: trim.end_ms,
      theme_fade_in_ms: trim.fade_in_ms,
      theme_fade_out_ms: trim.fade_out_ms
    })
  end

  defp record_auto_trim(item, _download), do: item

  # Writing the file is only half of it. Plex finds files and fetches metadata
  # in two separate stages, and neither runs on its own schedule when a sidecar
  # appears: without this the operator writes a theme, sees nothing play, and
  # goes looking for a button. So the same sequence the item page runs by hand
  # happens here -- scan the folder so Plex sees the file, refresh the item so
  # the agents run, then promote the theme if Plex listed it and served none.
  #
  # None of it can fail the apply. The file is on disk and correct either way,
  # and a Plex that is unreachable, or that refuses any step, is a thing to
  # report rather than a reason to mark a good write failed and retry it.
  defp hand_over_to_plex(item, plan) do
    with {:ok, config} <- Fanfarr.Config.plex_config(),
         {:ok, _before, state} <-
           Fanfarr.Plex.ThemeCheck.refresh_and_reread(config, item.plex_rating_key, scan(item)) do
      state = promote(config, item, plan, state)

      Library.record_plex_theme!(item, %{
        plex_theme_url: state.url,
        plex_theme_origin: state.origin,
        plex_theme_agent: state.agent,
        theme_locked: "theme" in (state[:locked_fields] || [])
      })

      log_outcome(item, plan, state)
    else
      {:error, :plex_not_configured} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "wrote #{plan.path} but could not get Plex to pick it up: #{inspect(reason)}"
        )
    end
  end

  # Plex is already serving something. Nothing to do.
  defp promote(_config, _item, _plan, %{url: url} = state) when is_binary(url), do: state

  # The theme field is locked, so Plex's agents will not write it however many
  # times the folder is scanned. Verified on a live server: a show with
  # `theme` locked kept its theme.mp3 listed and unselected forever, and an
  # upload took immediately -- an upload sets the field rather than asking an
  # agent to. Locking is why the local-file route cannot work here, so this
  # does not waste a request finding that out again.
  defp promote(config, item, plan, %{locked_fields: locked} = state) when is_list(locked) do
    if "theme" in locked do
      upload(config, item, plan, state)
    else
      select_then_upload(config, item, plan, state)
    end
  end

  defp promote(config, item, plan, state), do: select_then_upload(config, item, plan, state)

  # Selecting is the lighter touch -- it adopts the file already on disk rather
  # than storing a second copy inside Plex -- so it is tried first, and the
  # upload is the fallback when Plex will not take it.
  defp select_then_upload(
         config,
         item,
         plan,
         %{listed_not_selected: true, themes: [theme | _]} = state
       ) do
    case Fanfarr.Plex.ThemeCheck.select(config, item.plex_rating_key, theme.rating_key) do
      {:ok, %{url: url} = selected} when is_binary(url) -> selected
      _ -> upload(config, item, plan, state)
    end
  end

  defp select_then_upload(config, item, plan, state), do: upload(config, item, plan, state)

  defp upload(config, item, plan, state) do
    case Fanfarr.Plex.ThemeCheck.upload(config, item.plex_rating_key, plan.path) do
      {:ok, uploaded} ->
        uploaded

      {:error, reason} ->
        Logger.warning("Plex would not take an upload of #{plan.path}: #{inspect(reason)}")
        state
    end
  end

  defp log_outcome(item, plan, %{url: url}) when is_binary(url) do
    Logger.info("Plex is serving #{plan.path} for #{item.title}")
  end

  defp log_outcome(item, plan, _state) do
    Logger.warning(
      "wrote #{plan.path} for #{item.title} but Plex is still serving no theme; " <>
        "check that the library has \"Use local assets\" on"
    )
  end

  defp scan(item) do
    section = Ash.load!(item, :section).section

    if is_binary(item.plex_path) and item.plex_path != "" and is_binary(section.plex_key) do
      {section.plex_key, item.plex_path}
    end
  end

  defp download(plan) do
    # Downloaded into a scratch directory and only then moved next to the
    # media, so a failure part-way through never leaves a partial theme.mp3
    # where Plex can scan it.
    tmp = Path.join(System.tmp_dir!(), "fanfarr-dl-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      case obtain(plan.url, tmp, plan[:force]) do
        {:ok, %{path: downloaded} = result} ->
          # Cut BEFORE normalising, and the order is load-bearing. Normalizer
          # is two-pass: it measures integrated loudness and applies exactly
          # that gain. Measure the whole track and then throw most of it away
          # and the surviving segment is at whatever level it happened to be --
          # trim to a quiet intro and the theme is quiet, trim to the chorus
          # and it is hot. Every other theme in the library is level-matched;
          # cutting last would quietly exempt the cropped ones.
          #
          # The range is the operator's if there is one, and the automatic
          # answer if there is not -- see `resolve_trim/2`.
          {trim, automatic?} = resolve_trim(downloaded, plan.trim)
          result = cut(downloaded, trim, result)
          result = tag_auto_trim(result, trim, automatic?)

          # Before it is moved into place, so a normalisation that fails does
          # not leave a half-processed file next to the media.
          result = normalize(downloaded, result)

          case Themes.Writer.place(downloaded, plan.path) do
            :ok -> {:ok, result}
            {:error, reason} -> {:error, {:write_failed, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm_rf(tmp)
    end
  end

  # Themes arrive from Plex's agent, from ThemerrDB and from whatever the
  # operator picked, all mastered differently, so one show blasts and the next
  # is inaudible. Normalising is therefore part of applying, not a nicety.
  #
  # A failure here is logged and ignored: an unnormalised theme is worse than a
  # normalised one and far better than no theme, so this never turns a
  # successful download into a failed apply.
  # The trim editor leaves the original stream in the cache, and the very next
  # thing an operator does after trimming is press Apply. Reusing it skips the
  # download and renders from the better audio -- source -> cut -> mp3 rather
  # than source -> mp3 -> cut -> mp3.
  #
  # Only ever a `:source` entry: `fetch_source/1` refuses a `:render`, which is
  # an mp3 we wrote earlier and would compound its own losses. Otherwise the
  # cache is written on the edit path alone, or a bulk apply would fill the
  # volume for a run nobody is editing -- the one exception being a forced
  # redownload, which exists precisely to replace what is in there.
  defp obtain(url, tmp, force) do
    # A forced redownload skips the cache. The cache holds a lossless original
    # and exists to make re-trimming cheap, but "the file on disk is a
    # generation down and I want the source again" is precisely the question it
    # cannot answer, so this is the one caller that ignores it.
    lookup = if force, do: :miss, else: Themes.SourceCache.fetch_source(url)

    case lookup do
      {:ok, cached} ->
        # Copied into the scratch dir, because the pipeline cuts and normalises
        # in place and the cache is not ours to rewrite.
        working = Path.join(tmp, "source" <> Path.extname(cached.path))

        case File.cp(cached.path, working) do
          :ok ->
            {:ok,
             %{
               path: working,
               bytes: File.stat!(working).size,
               codec: nil,
               duration: nil,
               # The cached peaks carry the length of the stream they were
               # rendered from, which is what this file is until a cut
               # shortens it -- and the trim-then-apply flow, the whole reason
               # the cache exists, is exactly the one that never downloads.
               duration_ms: cached_duration(cached)
             }}

          {:error, _reason} ->
            Themes.Downloader.impl().download(url, tmp)
        end

      :miss ->
        downloaded = Themes.Downloader.impl().download(url, tmp)
        if force, do: remember(url, downloaded), else: downloaded
    end
  end

  # Puts a fresh download into the cache, so the next apply of this title works
  # from the source the operator just asked for rather than from the generation
  # they replaced. Copied first, because the pipeline cuts and normalises the
  # working copy in place and the cache is meant to keep the original.
  #
  # A cache that cannot be written is logged and stepped over: the theme file is
  # already correct by then, and a redownload that refused to finish because of
  # a full volume would be trading the thing that was asked for against a
  # convenience beside it.
  defp remember(url, {:ok, %{path: path}} = result) do
    staged = Path.join(Path.dirname(path), "cache-#{Path.basename(path)}")

    with :ok <- File.cp(path, staged),
         {:ok, _entry} <- Themes.SourceCache.put(url, staged, :source) do
      result
    else
      {:error, reason} ->
        Logger.warning(
          "[fanfarr] could not cache the redownloaded source (#{inspect(reason)}); " <>
            "the theme itself is written and correct"
        )

        File.rm(staged)
        result
    end
  end

  defp remember(_url, other), do: other

  # A chosen range wins: a crop the operator set is a decision, and a guess does
  # not outrank one. Fades alone are not a range -- but they are not nothing
  # either, because Plex loops themes and an uncropped one still wants its ends
  # softened, so they survive into whichever range gets cut.
  defp resolve_trim(path, trim) do
    if chosen?(trim), do: {trim, false}, else: {auto_trim(path, trim), true}
  end

  # Both ends, because a start without an end is not a range this pipeline can
  # write, and the item's fades default to on for every item there is.
  defp chosen?(trim), do: is_integer(trim[:start_ms]) and is_integer(trim[:end_ms])

  # The floor is the operator's -- three minutes by default -- and it is asked
  # here rather than anywhere near the trim button, because this is the
  # unattended case and the floor was only ever about that. A trim the operator
  # asks for skips it: see `Fanfarr.Workers.TrimTheme`.
  #
  # The audio is on disk by now, so the window is placed from the audio alone.
  # Asking YouTube's graph here would be a second network call for an answer
  # this file can give.
  defp auto_trim(path, trim) do
    fades = %{
      fade_in_ms: trim[:fade_in_ms] || Themes.Cutter.default_fade_in_ms(),
      fade_out_ms: trim[:fade_out_ms] || Themes.Cutter.default_fade_out_ms()
    }

    with true <- Themes.AutoCrop.enabled?(),
         {:ok, suggestion} <-
           Themes.AutoCrop.suggest_from_audio(path, min_ms: Themes.AutoCrop.min_ms()) do
      # Announced, because a theme that arrives shorter than the one that was
      # downloaded is otherwise a mystery the operator has to go and read the
      # settings to explain.
      Logger.info(
        "[fanfarr] cropping the download to #{div(Themes.AutoCrop.target_ms(), 1000)}s, " <>
          "starting at #{div(suggestion.start_ms, 1000)}s " <>
          "(source: #{suggestion.source})"
      )

      fades
      |> Map.put(:start_ms, suggestion.start_ms)
      |> Map.put(:end_ms, suggestion.end_ms)
    else
      # Off, too short to be worth it, or unreadable. All three mean the same
      # thing: no crop, and the fades the file would have had anyway.
      _ -> Map.merge(%{start_ms: nil, end_ms: nil}, fades)
    end
  end

  # Tagged only when the cut actually happened. `cut/3` merges the range into
  # the result on success and hands it back untouched when ffmpeg fails, so a
  # missing start means the file is whole and there is no crop to record.
  defp tag_auto_trim(result, _trim, false), do: result

  defp tag_auto_trim(%{start_ms: start} = result, trim, true) when is_integer(start),
    do: Map.put(result, :auto_trim, trim)

  defp tag_auto_trim(result, _trim, true), do: result

  # A no-op range does not get a re-encode: running ffmpeg to produce the same
  # audio costs a generation of lossy loss for nothing.
  defp cut(path, trim, result) do
    if Themes.Cutter.trims?(trim) do
      case Themes.Cutter.cut(path, trim) do
        {:ok, %{duration_ms: duration_ms}} ->
          Map.merge(result, %{
            bytes: File.stat!(path).size,
            duration_ms: duration_ms,
            start_ms: trim.start_ms,
            end_ms: trim.end_ms
          })

        {:error, reason} ->
          # The same trade normalisation makes: an untrimmed theme is not what
          # was asked for, but it is a theme, and failing the apply over the
          # fades would be worse than the fades.
          Logger.warning(
            "[fanfarr] could not trim the theme (#{inspect(reason)}); using it whole"
          )

          result
      end
    else
      result
    end
  end

  defp normalize(path, result) do
    case Fanfarr.Themes.Normalizer.normalize(path) do
      {:ok, measured} ->
        Logger.info(
          "[fanfarr] loudness #{Float.round(measured.before, 1)} -> " <>
            "#{Float.round(measured.after, 1)} LUFS (target #{measured.target})"
        )

        # Re-encoding changes the size, so the recorded byte count has to come
        # from the file that actually gets written.
        result
        |> Map.put(:loudness_lufs, measured.after)
        |> Map.put(:bytes, file_size(path, result[:bytes]))

      {:error, reason} ->
        Logger.warning(
          "[fanfarr] could not normalise loudness (#{inspect(reason)}); " <>
            "writing the file as downloaded"
        )

        result
    end
  end

  defp file_size(path, fallback) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> fallback
    end
  end

  # Transient conditions are worth another attempt; a rejected URL or an
  # unwritable directory will fail identically forever.
  #
  # A video YouTube has taken down, age-gated or geo-blocked is in the second
  # group, not the first. Retrying one costs five attempts with backoff to
  # arrive at the answer the first attempt already had, and leaves the item
  # sitting in the queue looking like work in progress. :unavailable used to
  # retry, which is what made a deleted video look like a flaky download.
  defp retry_or_stop(:timeout), do: {:error, :timeout}
  defp retry_or_stop({:exit, _, _} = reason), do: {:error, reason}
  defp retry_or_stop(reason), do: {:cancel, reason}

  defp writable?(dir) do
    probe = Path.join(dir, ".fanfarr-write-check")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, {:destination_not_writable, reason}}
    end
  end

  # --- logging ----------------------------------------------------------------

  defp blank_plan, do: %{url: nil, path: nil, source: :themerrdb}

  defp record_intent(item, plan) do
    # Broadcast here as well as on the outcome: the page should show that work
    # started, not just that it finished.
    broadcast(item)

    Themes.record_theme_intent!(%{
      media_item_id: item.id,
      source: plan.source,
      method: :local_file,
      theme_url: plan.url,
      destination_path: plan.path,
      start_ms: plan.trim.start_ms,
      end_ms: plan.trim.end_ms
    })
  end

  @doc """
  Turns a failure into a sentence the operator can act on.

  The history row is the only place most failures are ever read, and an
  inspected tuple is not a reason -- `{:exit, 1, "[youtube] Extracting URL:
  ..."}` reads as a crash when it means YouTube took the video down. Anything
  unrecognised still falls through to `inspect/1`, because a wrong sentence is
  worse than an ugly one.
  """
  @spec explain(term()) :: String.t()
  def explain(:unavailable),
    do: "YouTube no longer has this video — removed, private, or taken down. Pick another."

  def explain(:age_restricted),
    do: "YouTube wants an account to watch this one, so it cannot be downloaded. Pick another."

  def explain(:geo_blocked),
    do: "YouTube blocks this video in this server's region. Pick another."

  def explain(:not_installed),
    do: "yt-dlp is not installed in this container, so nothing can be downloaded. See System."

  def explain(:timeout), do: "The download did not finish in time."

  def explain(:no_plex_path),
    do: "Plex reports no folder for this item, so there is nowhere to write."

  def explain(:theme_locked), do: "This item's theme is locked in Plex."

  def explain(:no_themerrdb_entry),
    do: "ThemerrDB has no theme for this title, and no pick is set."

  def explain(:plex_not_configured), do: "Plex is not configured."

  def explain({:no_matching_root, path}),
    do: "No root folder holds #{path}. Add the drive under Settings, or check the path mappings."

  def explain({:not_in_own_folder, dir}),
    do:
      "#{dir} is a library root, not this title's own folder — a theme there would apply to everything beside it."

  def explain({:destination_missing, dir}), do: "#{dir} does not exist on this side of the mount."
  def explain({:write_failed, reason}), do: "Writing the file failed: #{inspect(reason)}"
  def explain({:exit, code, output}), do: "yt-dlp exited #{code}: #{String.trim(output)}"

  def explain({:http, status, ""}), do: "Plex answered #{status}."
  def explain({:http, status, detail}), do: "Plex answered #{status}: #{detail}"
  def explain({:http, status}), do: "Plex answered #{status}"
  def explain(other), do: inspect(other)

  defp record_outcome(item, plan, status, reason, download \\ %{}) do
    Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: plan[:source] || :themerrdb,
      method: :local_file,
      theme_url: plan[:url],
      destination_path: plan[:path],
      # The range that was written, which is the plan's when the operator chose
      # one and the pipeline's when it cropped on the way in. Read from the
      # download when it is there, because that is the file that got written:
      # a crop nothing asked for would otherwise leave no record of itself.
      start_ms: download[:start_ms] || get_in(plan, [:trim, :start_ms]),
      end_ms: download[:end_ms] || get_in(plan, [:trim, :end_ms]),
      status: status,
      error: reason && explain(reason),
      codec: download[:codec],
      bytes: download[:bytes],
      duration_ms: duration_ms(download),
      loudness_lufs: download[:loudness_lufs]
    })

    # After the row exists, so a subscriber that reloads sees the outcome.
    broadcast(item)
  end

  # The cutter reports milliseconds for the file it produced; the downloader
  # reports seconds for the video it fetched; the cache reports neither and is
  # asked separately. Whichever is present, it is the length of the file that
  # gets written -- a cut is the only thing that changes that between download
  # and write, and a cut overwrites this key.
  defp duration_ms(%{duration_ms: ms}) when is_integer(ms), do: ms
  defp duration_ms(%{duration: seconds}) when is_number(seconds), do: round(seconds * 1000)
  defp duration_ms(_result), do: nil

  # The peaks file beside the cached source, as the editor reads it.
  defp cached_duration(%{peaks: peaks}) do
    with {:ok, body} <- File.read(peaks),
         {:ok, %{"duration_ms" => ms}} <- Jason.decode(body),
         true <- is_integer(ms) do
      ms
    else
      _ -> nil
    end
  end

  defp broadcast(item) do
    Phoenix.PubSub.broadcast(Fanfarr.PubSub, "item:#{item.id}", {:item_updated, item.id})
  end

  @doc """
  Whether a job for this item is queued or running.

  Read from Oban rather than from the application log, because the gap that
  matters to someone watching the page is between clicking Apply and the
  worker picking the job up -- and during a bulk run on a two-slot queue that
  gap is minutes, with no log row written yet to show for it.
  """
  @spec in_flight?(String.t()) :: boolean()
  def in_flight?(item_id) when is_binary(item_id) do
    import Ecto.Query

    Fanfarr.Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == "Fanfarr.Workers.ApplyTheme",
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("json_extract(?, ?)", j.args, "$.media_item_id") == ^item_id
      )
    )
  end
end
