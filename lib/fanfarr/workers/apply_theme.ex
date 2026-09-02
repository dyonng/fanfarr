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
  use Oban.Worker,
    queue: :apply,
    max_attempts: 3,
    unique: [period: 300, keys: [:media_item_id], states: [:available, :scheduled, :executing]]

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Themes

  @theme_filename "theme.mp3"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id} = args}) do
    dry_run = Map.get(args, "dry_run", true)
    item = Library.get_media_item!(item_id)

    case plan(item) do
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

  # --- planning ---------------------------------------------------------------

  defp plan(item) do
    with :ok <- check_eligible(item),
         {:ok, url} <- theme_url(item),
         {:ok, dir} <- destination_dir(item) do
      {:ok, %{url: url, dir: dir, path: Path.join(dir, @theme_filename)}}
    end
  end

  defp check_eligible(%{theme_locked: true}), do: {:error, :theme_locked}

  defp check_eligible(%{kind: :movie}), do: {:error, :movies_not_supported_yet}

  defp check_eligible(_item), do: :ok

  # ThemerrDB is keyed by external id, so the entry is looked up the same way
  # LookupTheme wrote it.
  defp theme_url(item) do
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    [imdb: item.imdb_id, themoviedb: item.tmdb_id]
    |> Enum.filter(fn {_db, id} -> is_binary(id) and id != "" end)
    |> Enum.find_value({:error, :no_themerrdb_entry}, fn {db, id} ->
      case Themes.themerr_entry_for(item_type, db, id) do
        {:ok, %{found: true, youtube_theme_url: url}} when is_binary(url) and url != "" ->
          {:ok, url}

        _ ->
          nil
      end
    end)
  end

  defp destination_dir(%{plex_path: nil}), do: {:error, :no_plex_path}
  defp destination_dir(%{plex_path: ""}), do: {:error, :no_plex_path}

  defp destination_dir(item) do
    # to_local/2 returns the path unchanged when nothing matches, because the
    # common case is that Plex and Fanfarr see the library identically. So a
    # mapping never fails; what fails is the result not existing, which is the
    # symptom of a missing mount or a wrong mapping and is worth its own error.
    local = Fanfarr.PathMapping.to_local(item.plex_path, Fanfarr.Config.path_mappings())

    if Fanfarr.PathMapping.resolvable?(local) do
      resolve_root(local)
    else
      {:error, {:path_not_resolvable, local}}
    end
  end

  defp resolve_root(local_dir) do
    roots =
      Library.list_enabled_root_folders!()
      |> Enum.map(&%{id: &1.id, path: &1.path, kind: &1.kind})

    case Fanfarr.Library.RootFolders.resolve(local_dir, roots) do
      {:ok, dir, _how} -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp blank_plan, do: %{url: nil, path: nil}

  defp record_intent(item, plan, dry_run) do
    Themes.record_theme_intent!(%{
      media_item_id: item.id,
      source: :themerrdb,
      method: :local_file,
      theme_url: plan.url,
      destination_path: plan.path,
      dry_run: dry_run
    })
  end

  defp record_outcome(item, plan, dry_run, status, reason, download \\ %{}) do
    Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      source: :themerrdb,
      method: :local_file,
      theme_url: plan[:url],
      destination_path: plan[:path],
      dry_run: dry_run,
      status: status,
      error: reason && inspect(reason),
      codec: download[:codec],
      bytes: download[:bytes]
    })
  end
end
