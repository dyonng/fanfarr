defmodule Fanfarr.Workers.ApplyTheme do
  @moduledoc """
  Resolve a theme for one item and put it on disk.

  ## Dry run is the default, deliberately

  Writing a theme changes someone's media library, and the operator will
  usually be doing it to thousands of titles at once. A dry run walks the
  entire pipeline -- resolves the URL, resolves the destination directory,
  checks it is writable -- and stops before the download. It reports what it
  *would* do, which is the only way to find a misconfigured path mapping
  before it has been applied 1,785 times.

  Pass `"dry_run" => false` explicitly to actually write.

  ## Only local theme files, for now

  A theme.mp3 beside the media is reversible: deleting the file undoes it.
  Uploading through the Plex API is not, and the project's first rule is that
  irreversible actions need more care than this worker currently takes. Local
  files are also the well-established path for **TV shows**, which is the use
  case this exists for.

  Movies are a different question -- Plex's movie agent supplies no themes at
  all, and whether it reads a local theme file for a movie is **not something
  we have verified**. Rather than guess, movies are refused with a clear
  reason until that is tested on a real server. See AGENTS.md.

  ## Ordering

  The intent row is written before anything happens, so a crash mid-flight
  leaves evidence rather than silence. No database transaction spans the
  download.
  """
  # Unique per item *and* mode: with only the item as the key, a queued dry
  # run silently swallowed the real apply that followed it for five minutes,
  # which is precisely the order an operator does them in.
  use Oban.Worker,
    queue: :apply,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:media_item_id, :dry_run, :theme_url],
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Themes

  @theme_filename "theme.mp3"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id} = args}) do
    dry_run = Map.get(args, "dry_run", true)
    item = Library.get_media_item!(item_id)

    case plan(item, args) do
      {:ok, plan} ->
        record_intent(item, plan, dry_run)
        execute(item, plan, dry_run)

      {:error, reason} ->
        # A plan that cannot be made is a permanent condition -- a locked item,
        # an unmapped path, no ThemerrDB entry. Retrying does not help.
        record_outcome(item, blank_plan(), dry_run, :skipped, reason)
        {:cancel, reason}
    end
  end

  @doc """
  Queues this worker for an item.

  `:dry_run` defaults to true. `:theme_url` applies that URL instead of the
  item's manual pick or ThemerrDB entry -- used by "apply this one" from a
  search result, where the URL was just previewed.
  """
  @spec enqueue(Fanfarr.Library.MediaItem.t() | String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(item_or_id, opts \\ []) do
    id = if is_binary(item_or_id), do: item_or_id, else: item_or_id.id

    %{media_item_id: id, dry_run: Keyword.get(opts, :dry_run, true)}
    |> maybe_put(:theme_url, opts[:theme_url])
    |> maybe_put(:source, opts[:source])
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
      {:ok, %{url: url, source: source, dir: dir, path: Path.join(dir, @theme_filename)}}
    end
  end

  defp check_eligible(%{theme_locked: true}), do: {:error, :theme_locked}

  defp check_eligible(%{kind: :movie}), do: {:error, :movies_not_supported_yet}

  defp check_eligible(_item), do: :ok

  # Precedence: a URL passed with the job (just previewed in the UI), then the
  # operator's stored pick, then ThemerrDB. The operator's choice outranks the
  # database's because it was made looking at this specific title.
  defp theme_url(_item, %{"theme_url" => url} = args) when is_binary(url) and url != "" do
    {:ok, url, source_atom(args["source"], :youtube)}
  end

  defp theme_url(%{manual_theme_url: url}, _args) when is_binary(url) and url != "" do
    {:ok, url, :youtube}
  end

  defp theme_url(item, _args) do
    # ThemerrDB is keyed by external id, so the entry is looked up the same way
    # LookupTheme wrote it.
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    [imdb: item.imdb_id, themoviedb: item.tmdb_id]
    |> Enum.filter(fn {_db, id} -> is_binary(id) and id != "" end)
    |> Enum.find_value({:error, :no_themerrdb_entry}, fn {db, id} ->
      case Themes.themerr_entry_for(item_type, db, id) do
        {:ok, %{found: true, youtube_theme_url: url}} when is_binary(url) and url != "" ->
          {:ok, url, :themerrdb}

        _ ->
          nil
      end
    end)
  end

  defp source_atom("themerrdb", _), do: :themerrdb
  defp source_atom("youtube", _), do: :youtube
  defp source_atom(_, default), do: default

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

        if File.dir?(dir) do
          {:ok, dir}
        else
          {:error, {:destination_missing, dir}}
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

  defp execute(item, plan, true = dry_run) do
    # The point of a dry run is to fail here rather than in production, so the
    # destination is checked for real even though nothing is written.
    case writable?(plan.dir) do
      :ok ->
        record_outcome(item, plan, dry_run, :succeeded, nil)
        :ok

      {:error, reason} ->
        record_outcome(item, plan, dry_run, :failed, reason)
        {:cancel, reason}
    end
  end

  defp execute(item, plan, false = dry_run) do
    with :ok <- writable?(plan.dir),
         {:ok, download} <- download(plan) do
      record_outcome(item, plan, dry_run, :succeeded, nil, download)
      Library.record_local_theme!(item, %{local_theme_present: true, local_theme_path: plan.path})
      :ok
    else
      {:error, reason} ->
        record_outcome(item, plan, dry_run, :failed, reason)
        retry_or_stop(reason)
    end
  end

  defp download(plan) do
    # Downloaded into a scratch directory and only then moved next to the
    # media, so a failure part-way through never leaves a partial theme.mp3
    # where Plex can scan it.
    tmp = Path.join(System.tmp_dir!(), "fanfarr-dl-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      case Themes.Downloader.impl().download(plan.url, tmp) do
        {:ok, %{path: downloaded} = result} ->
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

  # Transient conditions are worth another attempt; a rejected URL or an
  # unwritable directory will fail identically forever.
  defp retry_or_stop(reason) when reason in [:timeout, :unavailable], do: {:error, reason}
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

  defp record_intent(item, plan, dry_run) do
    # Broadcast here as well as on the outcome: the page should show that work
    # started, not just that it finished.
    broadcast(item)

    Themes.record_theme_intent!(%{
      media_item_id: item.id,
      source: plan.source,
      method: :local_file,
      theme_url: plan.url,
      destination_path: plan.path,
      dry_run: dry_run
    })
  end

  defp record_outcome(item, plan, dry_run, status, reason, download \\ %{}) do
    Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: plan[:source] || :themerrdb,
      method: :local_file,
      theme_url: plan[:url],
      destination_path: plan[:path],
      dry_run: dry_run,
      status: status,
      error: reason && inspect(reason),
      codec: download[:codec],
      bytes: download[:bytes]
    })

    # After the row exists, so a subscriber that reloads sees the outcome.
    broadcast(item)
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
