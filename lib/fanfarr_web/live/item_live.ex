defmodule FanfarrWeb.ItemLive.Show do
  @moduledoc """
  One show or movie: its status, what ThemerrDB knows about it, the theme the
  operator picked by hand, and the full application history.

  This is also where a theme is *found*. ThemerrDB covers a fraction of a real
  library, and the stated job is the shows it does not know -- so the page
  searches YouTube, previews the result inline, and applies the very URL that
  was previewed. The history matters more here than anywhere: it is the
  record of what Fanfarr did to this item.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  import FanfarrWeb.LibraryLive.Index, only: [status_badge: 1]

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Plex.ThemeCheck
  alias Fanfarr.Themes.Downloader
  alias Fanfarr.Workers.ApplyTheme
  alias Fanfarr.Workers.LookupTheme

  @search_limit 8

  # Long enough not to hammer the database, short enough that a finished job
  # does not look stuck.
  @applying_poll 2_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Fanfarr.PubSub, "item:#{id}")

    socket =
      socket
      |> assign(:id, id)
      |> assign(:search_results, nil)
      |> assign(:search_error, nil)
      |> assign(:searching, false)
      |> assign(:previewing, nil)
      |> assign(:refreshing, false)
      |> assign(:looking_up, false)
      |> assign(:plex_theme_state, nil)
      |> assign(:plex_diagnosis, nil)
      |> assign(:diagnosing, false)
      |> assign(:selecting, false)
      |> assign(:poll_scheduled, false)
      |> assign(:uploading, false)
      |> load()
      |> track_applying()
      |> maybe_lookup()

    {:ok, assign(socket, :search_query, default_query(socket.assigns.item))}
  end

  # Opening an item is a request to know what ThemerrDB has for it, so the
  # lookup happens on arrival rather than behind a button nobody thinks to
  # press. The worker's own uniqueness window (an hour, keyed on the item)
  # means revisiting the page costs nothing upstream, and misses are cached,
  # so a title ThemerrDB does not know is asked about once.
  defp maybe_lookup(%{assigns: %{themerr: nil, item: item}} = socket) do
    cond do
      not connected?(socket) ->
        socket

      item.imdb_id in [nil, ""] and item.tmdb_id in [nil, ""] ->
        socket

      true ->
        case %{media_item_id: item.id} |> LookupTheme.new() |> Oban.insert() do
          {:ok, _job} -> assign(socket, :looking_up, true)
          {:error, _reason} -> socket
        end
    end
  end

  defp maybe_lookup(socket), do: socket

  # While a job is in flight, re-ask rather than waiting to be told.
  #
  # The worker broadcasts from *inside* perform/1, so Oban still has the job as
  # `executing` when the page reloads on that broadcast -- and there is no
  # second broadcast when it finally finishes. That was always a race the page
  # happened to win, because the gap between the broadcast and the job ending
  # was microseconds. Handing the file over to Plex put ten seconds in that gap
  # and the page started losing every time, leaving "Working on this item" up
  # forever. Polling ends the race rather than tightening it, and it also
  # recovers from a job that is discarded or killed, which no broadcast covers.
  defp track_applying(%{assigns: %{applying: true, poll_scheduled: false}} = socket) do
    if connected?(socket) do
      Process.send_after(self(), :recheck_applying, @applying_poll)
      assign(socket, :poll_scheduled, true)
    else
      socket
    end
  end

  defp track_applying(socket), do: socket

  defp load(socket) do
    item = Library.get_media_item!(socket.assigns.id, load: [:theme_status, :section])

    socket
    |> assign(:item, item)
    |> assign(:applying, ApplyTheme.in_flight?(item.id))
    # Changes when a theme is replaced, so the player refetches instead of
    # playing the previous file out of the browser cache.
    |> assign(:theme_version, theme_version(item))
    |> assign(:written, written_details(item))
    |> assign(:history, Fanfarr.Themes.theme_history_for_item!(item.id))
    |> assign(:themerr, themerr_entry(item))
    |> assign(:page_title, item.title)
  end

  defp themerr_entry(item) do
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    [imdb: item.imdb_id, themoviedb: item.tmdb_id]
    |> Enum.filter(fn {_db, id} -> id not in [nil, ""] end)
    |> Enum.find_value(fn {db, id} ->
      case Fanfarr.Themes.themerr_entry_for(item_type, db, id) do
        {:ok, entry} -> entry
        _ -> nil
      end
    end)
  end

  # The measurements from the run that produced the file now on disk, so
  # "is this in line with the rest of the library" is answerable here.
  defp written_details(item) do
    Fanfarr.Themes.theme_history_for_item!(item.id)
    |> Enum.find(&(&1.status == :succeeded and not &1.dry_run))
  end

  defp theme_version(%{local_theme_checked_at: nil}), do: 0

  defp theme_version(%{local_theme_checked_at: at}), do: DateTime.to_unix(at, :microsecond)

  # What people type into YouTube for this: the title, the year to
  # disambiguate remakes, and the word that finds the opening rather than a
  # trailer.
  defp default_query(item) do
    kind = if item.kind == :show, do: "opening theme", else: "main theme"
    [item.title, item.year, kind] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  # --- events ---------------------------------------------------------------

  @impl true
  def handle_event("preview", _params, socket) do
    queue(socket, dry_run: true, flash: "Dry run queued — nothing will be written")
  end

  def handle_event("apply", _params, socket) do
    queue(socket, dry_run: false, flash: "Theme queued for writing")
  end

  def handle_event("lookup", _params, socket) do
    case %{media_item_id: socket.assigns.item.id}
         |> LookupTheme.new()
         |> Oban.insert() do
      {:ok, _} -> {:noreply, socket |> assign(:looking_up, true)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not queue the lookup")}
    end
  end

  def handle_event("use_themerr", _params, socket) do
    case socket.assigns.themerr do
      %{youtube_theme_url: url} when is_binary(url) and url != "" ->
        set_manual(socket, url, "ThemerrDB suggestion")

      _ ->
        {:noreply, put_flash(socket, :error, "ThemerrDB has no suggestion for this item")}
    end
  end

  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q)

    if q == "" do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:search_query, q)
       |> assign(:searching, true)
       |> assign(:search_error, nil)
       |> start_async(:search, fn -> Downloader.impl().search(q, @search_limit) end)}
    end
  end

  def handle_event("preview_video", %{"id" => id}, socket) do
    {:noreply, assign(socket, :previewing, id)}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :previewing, nil)}
  end

  def handle_event("use_video", %{"url" => url} = params, socket) do
    set_manual(socket, url, params["title"])
  end

  def handle_event("use_url", %{"url" => url}, socket) do
    url = String.trim(url)

    if Downloader.youtube_url?(url) do
      set_manual(socket, url, nil)
    else
      {:noreply, put_flash(socket, :error, "That is not a YouTube URL")}
    end
  end

  def handle_event("refresh_plex", _params, socket) do
    item = socket.assigns.item

    case Fanfarr.Config.plex_config() do
      {:error, :plex_not_configured} ->
        {:noreply, put_flash(socket, :error, "Plex is not configured")}

      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:refreshing, true)
         |> start_async(:refresh_plex, fn ->
           ThemeCheck.refresh_and_reread(config, item.plex_rating_key, scan_target(item))
         end)}
    end
  end

  def handle_event("select_theme", %{"key" => theme_key}, socket) do
    item = socket.assigns.item

    # Logged on arrival, before anything can go wrong with it. Without this a
    # click that never reached the server and a click that reached it and
    # failed look identical in the console -- which is where an afternoon went.
    Logger.info("select_theme clicked for #{item.title}: #{theme_key}")

    case Fanfarr.Config.plex_config() do
      {:error, :plex_not_configured} ->
        {:noreply, put_flash(socket, :error, "Plex is not configured")}

      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:selecting, true)
         |> start_async(:select_theme, fn ->
           ThemeCheck.select(config, item.plex_rating_key, theme_key)
         end)}
    end
  end

  def handle_event("upload_theme", _params, socket) do
    item = socket.assigns.item

    case {Fanfarr.Config.plex_config(), item.local_theme_path} do
      {{:error, :plex_not_configured}, _} ->
        {:noreply, put_flash(socket, :error, "Plex is not configured")}

      {_, path} when path in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "There is no local file to upload yet")}

      {{:ok, config}, path} ->
        Logger.info("upload_theme clicked for #{item.title}: #{path}")

        {:noreply,
         socket
         |> assign(:uploading, true)
         |> start_async(:upload_theme, fn ->
           ThemeCheck.upload(config, item.plex_rating_key, path)
         end)}
    end
  end

  def handle_event("diagnose_plex", _params, socket) do
    item = socket.assigns.item

    case {Fanfarr.Config.plex_config(), scan_target(item)} do
      {{:error, :plex_not_configured}, _} ->
        {:noreply, put_flash(socket, :error, "Plex is not configured")}

      {_, nil} ->
        {:noreply,
         put_flash(socket, :error, "Fanfarr does not know this item's Plex path — sync first")}

      {{:ok, config}, {section_key, _dir}} ->
        {:noreply,
         socket
         |> assign(:diagnosing, true)
         |> start_async(:diagnose, fn ->
           config
           |> ThemeCheck.diagnose(item, section_key)
           |> Map.put(:file, Fanfarr.Themes.FileCheck.inspect_file(item.local_theme_path))
         end)}
    end
  end

  # No confirmation: one file, and re-applying is one click because the manual
  # pick and the ThemerrDB entry both survive the removal.
  def handle_event("remove_theme", _params, socket) do
    case Fanfarr.Themes.Remover.remove(socket.assigns.item) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(
           :info,
           "Theme file deleted. Plex may go on serving it until it re-reads the folder."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete the file: #{inspect(reason)}")}
    end
  end

  def handle_event("clear_manual", _params, socket) do
    Library.set_manual_theme!(socket.assigns.item, %{
      manual_theme_url: nil,
      manual_theme_title: nil
    })

    {:noreply,
     socket |> load() |> put_flash(:info, "Manual pick cleared; ThemerrDB is the source again")}
  end

  # Where to point Plex's scanner: its own view of the item's folder, plus the
  # section that folder belongs to. Both have to be known, and plex_path is the
  # one that goes missing -- a section listing does not always report it.
  defp scan_target(item) do
    section = Ash.load!(item, :section).section

    if is_binary(item.plex_path) and item.plex_path != "" and is_binary(section.plex_key) do
      {section.plex_key, item.plex_path}
    end
  end

  defp set_manual(socket, url, title) do
    Library.set_manual_theme!(socket.assigns.item, %{
      manual_theme_url: url,
      manual_theme_title: title
    })

    {:noreply,
     socket
     |> load()
     |> assign(:previewing, nil)
     |> put_flash(:info, "Saved as this item's theme. Apply to write it.")}
  end

  defp queue(socket, opts) do
    {flash, opts} = Keyword.pop(opts, :flash)

    case ApplyTheme.enqueue(socket.assigns.item, opts) do
      {:ok, _} ->
        # Set immediately rather than waiting for the worker's broadcast: the
        # click has to visibly do something, and on a busy queue the job may
        # not start for minutes.
        {:noreply,
         socket |> assign(:applying, true) |> track_applying() |> put_flash(:info, flash)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not queue the job")}
    end
  end

  @impl true
  def handle_async(:refresh_plex, {:ok, {:ok, before, current}}, socket) do
    # Store it the same way a sync would, so the status badge and the Plex card
    # agree with what we just read rather than with the last full sync.
    item =
      Library.record_plex_theme!(socket.assigns.item, plex_theme_attrs(current))

    {level, message} = ThemeCheck.verdict(current, item)

    state =
      current
      |> Map.put(:changed, ThemeCheck.changed?(before, current))
      |> Map.put(:level, level)
      |> Map.put(:message, message)

    # The reading itself is a paragraph and belongs on the page, next to the
    # evidence it is drawn from. The flash only says the round trip finished.
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> assign(:plex_theme_state, state)
     |> load()
     |> put_flash(:info, "Plex refreshed — see what it serves now, below.")}
  end

  def handle_async(:refresh_plex, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> put_flash(:error, "Plex refused the refresh: #{inspect(reason)}")}
  end

  def handle_async(:refresh_plex, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> put_flash(:error, "Refresh crashed: #{inspect(reason, limit: 5)}")}
  end

  def handle_async(:select_theme, {:ok, {:ok, current}}, socket) do
    item =
      Library.record_plex_theme!(socket.assigns.item, plex_theme_attrs(current))

    {:noreply,
     socket
     |> assign(:selecting, false)
     |> assign(:item, item)
     |> assign(:plex_theme_state, restate(socket.assigns.plex_theme_state, current, item))
     |> load()}
  end

  def handle_async(:select_theme, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:selecting, false) |> select_failed(reason)}
  end

  def handle_async(:upload_theme, {:ok, {:ok, current}}, socket) do
    item =
      Library.record_plex_theme!(socket.assigns.item, plex_theme_attrs(current))

    {:noreply,
     socket
     |> assign(:uploading, false)
     |> assign(:item, item)
     |> assign(:plex_theme_state, restate(socket.assigns.plex_theme_state, current, item))
     |> load()}
  end

  def handle_async(:upload_theme, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:uploading, false)
     |> select_failed({:upload_refused, reason})}
  end

  def handle_async(:upload_theme, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:uploading, false)
     |> select_failed({:upload_crashed, inspect(reason, limit: 5)})}
  end

  def handle_async(:select_theme, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(:selecting, false) |> select_failed({:crashed, inspect(reason, limit: 5)})}
  end

  def handle_async(:diagnose, {:ok, report}, socket) do
    {:noreply, socket |> assign(:diagnosing, false) |> assign(:plex_diagnosis, report)}
  end

  def handle_async(:diagnose, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:diagnosing, false)
     |> put_flash(:error, "The check crashed: #{inspect(reason, limit: 5)}")}
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, hits}}, socket) do
    {:noreply, socket |> assign(:searching, false) |> assign(:search_results, hits)}
  end

  def handle_async(:search, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:search_results, [])
     |> assign(:search_error, search_error(reason))}
  end

  def handle_async(:search, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:search_results, [])
     |> assign(:search_error, "Search crashed: #{inspect(reason, limit: 5)}")}
  end

  defp file_summary({:ok, info}) do
    [
      info.format || "unknown format",
      info.codec,
      info.duration && "#{info.duration}s",
      info.sample_rate && "#{info.sample_rate} Hz",
      info.channels && "#{info.channels} ch",
      info.bit_rate && "#{div(info.bit_rate, 1000)} kbps",
      format_bytes(info.bytes)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp file_summary({:error, {:empty, _}}), do: "the file is zero bytes"

  defp file_summary({:error, {:unreadable, bytes}}),
    do:
      "#{format_bytes(bytes)} on disk, but ffprobe cannot decode it — this is not playable audio"

  defp file_summary({:error, {:missing, reason}}), do: "cannot be read: #{inspect(reason)}"
  defp file_summary({:error, :no_file}), do: "nothing written yet"
  defp file_summary(_), do: "not checked"

  defp scan_result(:ok), do: "Plex accepted the scan request"
  defp scan_result(:not_attempted), do: "not attempted — Plex path unknown"
  defp scan_result({:error, reason}), do: "refused: #{inspect(reason)}"
  defp scan_result(_), do: "—"

  # Keeps whatever the last refresh established about the steps it took, and
  # replaces only what Plex now serves.
  # Failures land in the panel beside the evidence, not only in a flash. A
  # flash that has already faded is indistinguishable from a button that did
  # nothing, which is what "nothing happened" turned out to mean.
  defp select_failed(socket, reason) do
    state =
      (socket.assigns.plex_theme_state || %{})
      |> Map.merge(%{
        level: :warning,
        message: "Plex refused the request to serve that theme: #{inspect(reason)}"
      })

    socket
    |> assign(:plex_theme_state, state)
    |> put_flash(:error, "Plex refused: #{inspect(reason)}")
  end

  # theme_locked is only known when Plex was actually asked; a read that did
  # not report the fields must not be taken as "unlocked".
  defp plex_theme_attrs(%{locked_fields: locked} = state) when is_list(locked) do
    state |> plex_theme_attrs(:base) |> Map.put(:theme_locked, "theme" in locked)
  end

  defp plex_theme_attrs(state), do: plex_theme_attrs(state, :base)

  defp plex_theme_attrs(state, :base) do
    %{
      plex_theme_url: state.url,
      plex_theme_origin: state.origin,
      plex_theme_agent: state.agent
    }
  end

  defp restate(previous, current, item) do
    {level, message} = ThemeCheck.verdict(current, item)

    # A 200 from Plex is not evidence the selection took, so the verdict is
    # drawn from the read-back and the panel says which of the two happened.
    {level, message} =
      if current.url do
        {level, message}
      else
        {:warning,
         "Plex accepted the request but is still serving no theme. " <>
           "The endpoint that selects a theme is inferred from Plex's convention " <>
           "for posters, so this may mean it is not the right call. " <> message}
      end

    previous
    |> Kernel.||(%{})
    |> Map.merge(current)
    |> Map.merge(%{level: level, message: message, changed: true})
  end

  defp search_error(:not_installed),
    do: "yt-dlp is not installed in this container, so search is unavailable. See System."

  defp search_error(:timeout), do: "YouTube did not answer in time"
  defp search_error({:exit, _code, out}), do: "yt-dlp failed: #{out}"
  defp search_error(other), do: "Search failed: #{inspect(other)}"

  @impl true
  def handle_info({:item_updated, _id}, socket),
    do: {:noreply, socket |> load() |> track_applying() |> assign(:looking_up, false)}

  def handle_info(:recheck_applying, socket) do
    {:noreply,
     socket
     |> assign(:poll_scheduled, false)
     |> load()
     |> track_applying()}
  end

  # --- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={:library}
      current_user={@current_user}
      queue_summary={@queue_summary}
    >
      <div class="space-y-6">
        <div class="flex items-start gap-5">
          <img
            src={~p"/posters/#{@item.id}"}
            alt=""
            class="hidden w-28 shrink-0 rounded-md bg-muted object-cover shadow sm:block"
            style="aspect-ratio: 2 / 3"
          />
          <div class="min-w-0 flex-1">
            <.link navigate={~p"/"} class="text-sm text-muted-foreground hover:text-foreground">
              ← Library
            </.link>
            <div class="mt-1 flex flex-wrap items-start justify-between gap-3">
              <div>
                <h1 class="text-2xl font-semibold tracking-tight">
                  {@item.title}
                  <span :if={@item.year} class="ml-1 font-normal text-muted-foreground">
                    ({@item.year})
                  </span>
                </h1>
                <p class="mt-1 text-sm text-muted-foreground">
                  {if @item.kind == :show, do: "Series", else: "Movie"}
                  <span :if={@item.section}> · {@item.section.title}</span>
                </p>
              </div>
              <.status_badge status={@item.theme_status} />
            </div>

            <div class="mt-4 flex flex-wrap items-center gap-2">
              <button
                phx-click="preview"
                disabled={@applying}
                class="inline-flex h-9 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground disabled:cursor-not-allowed disabled:opacity-50"
                title="Resolves the theme and the destination, checks it is writable, writes nothing"
              >
                <.icon name="lucide-flask-conical" class="size-4" /> Preview (dry run)
              </button>
              <button
                phx-click="apply"
                disabled={@applying or @item.theme_locked}
                class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
                title={apply_title(@item)}
              >
                <.icon
                  :if={@applying}
                  name="lucide-loader-circle"
                  class="size-4 animate-spin"
                />
                <.icon :if={!@applying} name="lucide-music" class="size-4" />
                {if @applying, do: "Working…", else: "Apply theme"}
              </button>
              <button
                phx-click="lookup"
                class="inline-flex h-9 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground"
              >
                <.icon name="lucide-database" class="size-4" /> Look up ThemerrDB
              </button>
            </div>
            <p :if={@item.kind == :movie} class="mt-2 text-xs text-muted-foreground">
              Plex's movie agent supplies no themes of its own, so this is the only way a film gets
              one. It reads the local file the same as a show does.
            </p>
          </div>
        </div>

        <div
          :if={@applying}
          class="flex items-center gap-3 rounded-lg border border-primary/40 bg-primary/5 px-4 py-3 text-sm"
        >
          <.icon name="lucide-loader-circle" class="size-4 animate-spin text-primary" />
          <div>
            <p class="font-medium">Working on this item</p>
            <p class="text-xs text-muted-foreground">
              Downloading the audio, writing it beside the media, and then getting Plex to pick it
              up — a scan of the folder, a refresh, and a nudge if Plex lists the theme without
              playing it. That last part takes a few seconds on its own. This page updates itself
              when the job finishes, and a queued job waits its turn behind any others.
            </p>
          </div>
        </div>

        <section
          :if={@item.local_theme_present and @item.local_theme_path}
          class="rounded-lg border border-border bg-card p-4"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <h2 class="text-sm font-semibold text-card-foreground">The file Fanfarr wrote</h2>
              <p
                class="break-all font-mono text-xs text-muted-foreground"
                title={@item.local_theme_path}
              >
                {@item.local_theme_path}
              </p>
              <p :if={@written} class="mt-1 text-xs text-muted-foreground">
                <span :if={@written.loudness_lufs}>
                  {Float.round(@written.loudness_lufs, 1)} LUFS
                  <span class="opacity-70">
                    (normalised to {Fanfarr.Themes.Normalizer.target()})
                  </span>
                  ·
                </span>
                <span :if={@written.bytes}>{format_bytes(@written.bytes)}</span>
                <span :if={@written.codec}> · {@written.codec}</span>
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <button
                phx-click="refresh_plex"
                disabled={@refreshing}
                class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground disabled:opacity-60"
                title="Plex does not watch for new local theme files; it has to be told to look again"
              >
                <.icon
                  name="lucide-refresh-cw"
                  class={["size-3.5", @refreshing && "animate-spin"]}
                /> {if @refreshing, do: "Asking Plex…", else: "Refresh in Plex"}
              </button>
              <button
                phx-click="remove_theme"
                class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs text-muted-foreground hover:border-destructive/40 hover:bg-destructive/10 hover:text-destructive"
                title="Delete the theme.mp3 Fanfarr wrote. Anything already uploaded into Plex itself stays -- Plex has no API to remove that."
              >
                <.icon name="lucide-trash-2" class="size-3.5" /> Remove theme
              </button>
            </div>
          </div>

          <%!-- The browser's own audio controls render in its default chrome,
          which is a white bar in a dark UI and ignores the theme entirely. This
          is the same element underneath, with the controls drawn from our own
          tokens. Keyed on the theme version so a newly written file replaces
          the node rather than the browser continuing with the previous one. --%>
          <div
            id={"theme-player-#{@theme_version}"}
            phx-hook=".AudioPlayer"
            data-src={~p"/library/#{@item.id}/theme?v=#{@theme_version}"}
            class="mt-3 flex items-center gap-3 rounded-md border border-border bg-background px-3 py-2"
          >
            <button
              type="button"
              data-play
              aria-label="Play"
              class="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground hover:bg-primary/90"
            >
              <span data-icon="play"><.icon name="lucide-play" class="size-4" /></span>
              <span data-icon="pause" class="hidden">
                <.icon name="lucide-pause" class="size-4" />
              </span>
            </button>

            <div
              data-track
              role="slider"
              aria-label="Seek"
              tabindex="0"
              class="relative h-2 flex-1 cursor-pointer rounded-full bg-muted"
            >
              <div data-fill class="absolute inset-y-0 left-0 w-0 rounded-full bg-primary"></div>
            </div>

            <span data-time class="shrink-0 font-mono text-xs tabular-nums text-muted-foreground">
              0:00 / 0:00
            </span>

            <button
              type="button"
              data-mute
              aria-label="Mute"
              class="shrink-0 rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-accent-foreground"
            >
              <span data-icon="unmuted"><.icon name="lucide-volume-2" class="size-4" /></span>
              <span data-icon="muted" class="hidden">
                <.icon name="lucide-volume-x" class="size-4" />
              </span>
            </button>

            <input
              type="range"
              data-volume
              min="0"
              max="1"
              step="0.01"
              aria-label="Volume"
              class="h-1.5 w-20 shrink-0 cursor-pointer accent-primary"
            />
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".AudioPlayer">
            export default {
              mounted() {
                const el = this.el
                // Built here rather than rendered as <audio>, so there is no
                // native control bar to hide and restyle.
                const audio = new Audio(el.dataset.src)
                // metadata, not none: the range-capable endpoint means this
                // costs a few kilobytes and fills in the duration up front.
                audio.preload = "metadata"
                this.audio = audio

                const playIcon = el.querySelector('[data-icon="play"]')
                const pauseIcon = el.querySelector('[data-icon="pause"]')
                const unmuted = el.querySelector('[data-icon="unmuted"]')
                const muted_ = el.querySelector('[data-icon="muted"]')
                const fill = el.querySelector("[data-fill]")
                const track = el.querySelector("[data-track]")
                const time = el.querySelector("[data-time]")
                const playButton = el.querySelector("[data-play]")

                const clock = (seconds) => {
                  if (!isFinite(seconds)) return "0:00"
                  const total = Math.floor(seconds)
                  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`
                }

                const paint = () => {
                  const done = audio.duration ? (audio.currentTime / audio.duration) * 100 : 0
                  fill.style.width = `${done}%`
                  time.textContent = `${clock(audio.currentTime)} / ${clock(audio.duration)}`
                }

                const showPlaying = (playing) => {
                  playIcon.classList.toggle("hidden", playing)
                  pauseIcon.classList.toggle("hidden", !playing)
                  playButton.setAttribute("aria-label", playing ? "Pause" : "Play")
                }

                playButton.addEventListener("click", () => {
                  if (audio.paused) { audio.play() } else { audio.pause() }
                })

                el.querySelector("[data-mute]").addEventListener("click", () => {
                  window.Fanfarr.volume.set({muted: !audio.muted})
                })

                track.addEventListener("click", (event) => {
                  const box = track.getBoundingClientRect()
                  const ratio = Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1)
                  if (isFinite(audio.duration)) { audio.currentTime = ratio * audio.duration }
                })

                audio.addEventListener("play", () => showPlaying(true))
                audio.addEventListener("pause", () => showPlaying(false))
                audio.addEventListener("ended", () => { showPlaying(false); paint() })
                audio.addEventListener("timeupdate", paint)
                audio.addEventListener("loadedmetadata", paint)
                audio.addEventListener("error", () => { time.textContent = "could not load" })

                // Volume is shared with the YouTube preview and outlives the
                // page, so it is never read off the element -- the store is the
                // only source, and the slider is just one way to write to it.
                const store = window.Fanfarr.volume
                const slider = el.querySelector("[data-volume]")

                this.unsubscribe = store.subscribe(({level, muted}) => {
                  audio.volume = level
                  audio.muted = muted
                  slider.value = level
                  unmuted.classList.toggle("hidden", muted)
                  muted_.classList.toggle("hidden", !muted)
                })

                slider.addEventListener("input", () => {
                  // Moving the slider off zero is an unmute: leaving it muted
                  // while the slider reads 60% is the kind of thing people
                  // spend a minute staring at.
                  store.set({level: Number(slider.value), muted: false})
                })
              },

              destroyed() {
                // Without this the previous theme keeps playing after a new one
                // replaces this node.
                if (this.audio) { this.audio.pause(); this.audio.src = "" }
                if (this.unsubscribe) { this.unsubscribe() }
              }
            }
          </script>

          <p class="mt-2 text-xs text-muted-foreground">
            Listen before trusting it: a download can succeed and still be the wrong track. If the
            show has no theme in Plex yet, use Refresh in Plex above — Plex does not notice a new
            local theme file on its own.
          </p>

          <%!-- The read-back from the refresh. The raw ratingKeys are shown on
          purpose: which scheme Plex uses for a theme it picked up from a local
          file is the one case we have not been able to verify against a live
          server, so when it appears here it is worth being able to read it. --%>
          <div
            :if={@plex_theme_state}
            class={[
              "mt-3 rounded-md border p-3 text-sm",
              @plex_theme_state.level == :warning &&
                "border-destructive/40 bg-destructive/10 text-destructive-foreground",
              @plex_theme_state.level != :warning && "border-border bg-background"
            ]}
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              What Plex serves now
            </p>
            <p class="mt-1">{@plex_theme_state.message}</p>

            <dl class="mt-3 space-y-1 text-xs">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Theme</dt>
                <dd class="break-all text-right font-mono">{@plex_theme_state.url || "none"}</dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Origin</dt>
                <dd>
                  {@plex_theme_state.origin}{if @plex_theme_state.agent,
                    do: " · #{@plex_theme_state.agent}"}
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Folder scan</dt>
                <dd>{scan_result(@plex_theme_state[:scanned])}</dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Changed by the refresh</dt>
                <dd>{if @plex_theme_state.changed, do: "yes", else: "no"}</dd>
              </div>
            </dl>

            <div class="mt-3 border-t border-border/60 pt-3">
              <%!-- The other way round from "use this one": that asks Plex to
              serve a theme it already lists, this hands it the bytes. They
              fail differently, and on this server selection answers 500. --%>
              <button
                :if={@item.local_theme_path not in [nil, ""]}
                phx-click="upload_theme"
                disabled={@uploading}
                class="mr-2 inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground disabled:opacity-60"
                title="Send the file to Plex instead of asking it to read the one on disk"
              >
                <.icon
                  :if={@uploading}
                  name="lucide-loader-circle"
                  class="size-3.5 animate-spin"
                /> {if @uploading, do: "Uploading…", else: "Upload to Plex"}
              </button>
              <button
                phx-click="diagnose_plex"
                disabled={@diagnosing}
                class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground disabled:opacity-60"
              >
                <.icon
                  :if={@diagnosing}
                  name="lucide-loader-circle"
                  class="size-3.5 animate-spin"
                /> Ask Plex why
              </button>

              <%!-- Reported as Plex phrased it. Which preference governs theme
              music differs between the legacy agents and tv.plex.agents.*, and
              inventing a mapping we have not verified is how the `provider`
              field got made up in the first place. --%>
              <div :if={@plex_diagnosis} class="mt-3 space-y-3 text-xs">
                <%!-- The one setting that decides whether Plex reads sidecar
                files at all. With it off the scanner and the agents are both
                behaving correctly and simply not looking, so this outranks
                everything else the check reports. --%>
                <p
                  :if={ThemeCheck.local_assets_off?(@plex_diagnosis.prefs) == true}
                  class="rounded-md border border-destructive/40 bg-destructive/10 p-2 text-destructive-foreground"
                >
                  <strong>This library has "Use local assets" turned off.</strong>
                  Plex will not read theme.mp3 beside the media while that is off, so no amount of
                  refreshing will pick it up. In Plex: {@plex_diagnosis.section["title"]} → Edit →
                  Advanced → Use local assets, then refresh here again.
                </p>

                <div>
                  <p class="font-semibold text-muted-foreground">Library</p>
                  <p class="mt-0.5 font-mono">
                    {@plex_diagnosis.section["title"]} · agent {@plex_diagnosis.section["agent"] ||
                      "unknown"} · scanner {@plex_diagnosis.section["scanner"] || "unknown"}
                  </p>
                </div>

                <%!-- Plex listing a theme it will not serve, and answering 500
                when asked to select that one, are both consistent with a file
                it can index and not decode. ffprobe settles it. --%>
                <div>
                  <p class="font-semibold text-muted-foreground">The file on disk</p>
                  <p class="mt-0.5 font-mono">{file_summary(@plex_diagnosis[:file])}</p>
                </div>

                <div :if={is_list(@plex_diagnosis[:locked_fields])}>
                  <p class="font-semibold text-muted-foreground">Fields Plex has locked</p>
                  <p class="mt-0.5">
                    {if @plex_diagnosis.locked_fields == [],
                      do: "none",
                      else: Enum.join(@plex_diagnosis.locked_fields, ", ")}
                  </p>
                </div>

                <div :if={is_list(@plex_diagnosis.seasons)}>
                  <p class="font-semibold text-muted-foreground">Seasons Plex lists</p>
                  <p class="mt-0.5">
                    {length(@plex_diagnosis.seasons)}
                    <span :if={@plex_diagnosis.seasons != []}>
                      — {Enum.join(@plex_diagnosis.seasons, ", ")}
                    </span>
                  </p>
                </div>

                <div>
                  <p class="font-semibold text-muted-foreground">Folders</p>
                  <p class="mt-0.5 break-all font-mono">
                    Plex holds: {if @plex_diagnosis.plex_locations == [],
                      do: @plex_diagnosis.plex_path || "nothing",
                      else: Enum.join(@plex_diagnosis.plex_locations, ", ")}
                  </p>
                  <p class="break-all font-mono">
                    We wrote: {@plex_diagnosis.wrote_to || "nothing"}
                  </p>
                </div>

                <div :if={ThemeCheck.local_asset_prefs(@plex_diagnosis.prefs) != []}>
                  <p class="font-semibold text-muted-foreground">
                    Settings mentioning local assets or themes
                  </p>
                  <dl class="mt-0.5 space-y-0.5">
                    <div
                      :for={pref <- ThemeCheck.local_asset_prefs(@plex_diagnosis.prefs)}
                      class="flex justify-between gap-4"
                    >
                      <dt class="text-muted-foreground">{pref.label || pref.id}</dt>
                      <dd class="font-mono">{to_string(pref.value)}</dd>
                    </div>
                  </dl>
                </div>

                <details :if={@plex_diagnosis.prefs != []}>
                  <summary class="cursor-pointer text-muted-foreground hover:underline">
                    all {length(@plex_diagnosis.prefs)} library settings
                  </summary>
                  <dl class="mt-1 space-y-0.5">
                    <div :for={pref <- @plex_diagnosis.prefs} class="flex justify-between gap-4">
                      <dt class="text-muted-foreground">{pref.label || pref.id}</dt>
                      <dd class="font-mono">{to_string(pref.value)}</dd>
                    </div>
                  </dl>
                </details>

                <p :if={@plex_diagnosis.prefs == []} class="text-muted-foreground">
                  Plex returned no settings for this library.
                </p>
              </div>
            </div>

            <details :if={@plex_theme_state.themes != []} class="mt-2">
              <summary class="cursor-pointer text-xs text-muted-foreground hover:underline">
                {length(@plex_theme_state.themes)} theme{if length(@plex_theme_state.themes) != 1,
                  do: "s"} listed by Plex
              </summary>
              <ul class="mt-1 space-y-1">
                <li :for={theme <- @plex_theme_state.themes} class="text-xs">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={[
                      "font-medium",
                      theme.selected && "text-foreground",
                      !theme.selected && "text-muted-foreground"
                    ]}>
                      {if theme.selected, do: "playing", else: "listed, not selected"}
                    </span>
                    <button
                      :if={!theme.selected and theme.rating_key}
                      phx-click="select_theme"
                      phx-value-key={theme.rating_key}
                      disabled={@selecting}
                      class="rounded-md border border-border px-2 py-0.5 hover:bg-accent hover:text-accent-foreground disabled:opacity-60"
                      title="Tell Plex to serve this one"
                    >
                      {if @selecting, do: "asking…", else: "use this one"}
                    </button>
                  </div>
                  <span class="mt-0.5 block break-all font-mono text-muted-foreground">
                    {theme.rating_key || theme.key}
                  </span>
                </li>
              </ul>
            </details>
          </div>
        </section>

        <div class="grid gap-4 lg:grid-cols-3">
          <section class="rounded-lg border border-border bg-card p-4">
            <h2 class="text-sm font-semibold text-card-foreground">Plex</h2>
            <dl class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Reported path</dt>
                <dd class="truncate font-mono text-xs" title={@item.plex_path}>
                  {@item.plex_path || "—"}
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Theme on server</dt>
                <dd class="text-right">{theme_origin_label(@item)}</dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Theme locked</dt>
                <dd>{if @item.theme_locked, do: "yes", else: "no"}</dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">IDs</dt>
                <dd class="text-right font-mono text-xs">
                  {[
                    @item.imdb_id && "imdb:#{@item.imdb_id}",
                    @item.tmdb_id && "tmdb:#{@item.tmdb_id}",
                    @item.tvdb_id && "tvdb:#{@item.tvdb_id}"
                  ]
                  |> Enum.reject(&is_nil/1)
                  |> Enum.join("  ")
                  |> then(&if(&1 == "", do: "—", else: &1))}
                </dd>
              </div>
            </dl>
          </section>

          <section class="rounded-lg border border-border bg-card p-4">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-card-foreground">ThemerrDB</h2>
              <button
                :if={not @looking_up}
                phx-click="lookup"
                class="text-xs text-muted-foreground hover:underline"
                title="Ask ThemerrDB again"
              >
                look up again
              </button>
              <span
                :if={@looking_up}
                class="inline-flex items-center gap-1.5 text-xs text-muted-foreground"
              >
                <.icon name="lucide-loader-circle" class="size-3.5 animate-spin" /> looking up…
              </span>
            </div>

            <div :if={@themerr == nil} class="mt-3 text-sm text-muted-foreground">
              <span :if={@looking_up}>Asking ThemerrDB about this title…</span>
              <span :if={
                not @looking_up and (@item.imdb_id not in [nil, ""] or @item.tmdb_id not in [nil, ""])
              }>
                No answer yet.
              </span>
              <span :if={
                not @looking_up and @item.imdb_id in [nil, ""] and @item.tmdb_id in [nil, ""]
              }>
                Plex reports no IMDB or TMDB id for this item, and ThemerrDB is keyed on those.
                Nothing to look up.
              </span>
            </div>

            <dl :if={@themerr} class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">In database</dt>
                <dd>{if @themerr.found, do: "yes", else: "no"}</dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Checked</dt>
                <dd>{Calendar.strftime(@themerr.fetched_at, "%Y-%m-%d %H:%M")}</dd>
              </div>
            </dl>

            <div
              :if={@themerr && @themerr.youtube_theme_url}
              class="mt-3 space-y-2 border-t border-border/60 pt-3"
            >
              <p class="text-xs text-muted-foreground">Suggests</p>
              <p
                class="break-all font-mono text-xs text-muted-foreground"
                title={@themerr.youtube_theme_url}
              >
                {@themerr.youtube_theme_url}
              </p>
              <div class="flex flex-wrap items-center gap-2">
                <button
                  :if={Downloader.youtube_id(@themerr.youtube_theme_url)}
                  phx-click="preview_video"
                  phx-value-id={Downloader.youtube_id(@themerr.youtube_theme_url)}
                  class="inline-flex h-8 items-center gap-1 rounded-md border border-border px-2 text-xs hover:bg-accent hover:text-accent-foreground"
                >
                  <.icon name="lucide-play" class="size-3.5" /> Preview
                </button>
                <button
                  :if={@item.manual_theme_url != @themerr.youtube_theme_url}
                  phx-click="use_themerr"
                  class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-2 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                  title="Pin this as the item's pick so a later ThemerrDB edit cannot change it"
                >
                  <.icon name="lucide-check" class="size-3.5" /> Use this
                </button>
                <a
                  href={@themerr.youtube_theme_url}
                  target="_blank"
                  rel="noopener"
                  class="text-xs text-muted-foreground hover:underline"
                >
                  open on YouTube ↗
                </a>
              </div>
            </div>

            <p
              :if={@themerr != nil and @themerr.found and @themerr.youtube_theme_url in [nil, ""]}
              class="mt-3 text-sm text-muted-foreground"
            >
              ThemerrDB knows this title but has no theme for it.
            </p>
          </section>

          <section class="rounded-lg border border-border bg-card p-4">
            <h2 class="text-sm font-semibold text-card-foreground">Your pick</h2>
            <div :if={@item.manual_theme_url in [nil, ""]} class="mt-3 text-sm text-muted-foreground">
              None. ThemerrDB's suggestion is used, if it has one. Search below to choose your own.
            </div>
            <div :if={@item.manual_theme_url not in [nil, ""]} class="mt-3 space-y-2 text-sm">
              <p class="font-medium">{@item.manual_theme_title || "Chosen video"}</p>
              <p
                class="break-all font-mono text-xs text-muted-foreground"
                title={@item.manual_theme_url}
              >
                {@item.manual_theme_url}
              </p>
              <div class="flex gap-3 text-xs">
                <button
                  :if={Downloader.youtube_id(@item.manual_theme_url)}
                  phx-click="preview_video"
                  phx-value-id={Downloader.youtube_id(@item.manual_theme_url)}
                  class="text-primary hover:underline"
                >
                  play preview
                </button>
                <button phx-click="clear_manual" class="text-muted-foreground hover:underline">
                  clear
                </button>
              </div>
              <p class="text-xs text-muted-foreground">Outranks ThemerrDB when applying.</p>
            </div>
          </section>
        </div>

        <section id="find-theme" class="rounded-lg border border-border bg-card">
          <div class="border-b border-border px-4 py-3">
            <h2 class="text-sm font-semibold text-card-foreground">Find a theme</h2>
            <p class="text-xs text-muted-foreground">
              Search YouTube from here, listen, and pick. What you pick is exactly what gets applied.
            </p>
          </div>

          <div class="space-y-4 p-4">
            <form id="theme-search" phx-submit="search" class="flex gap-2">
              <input
                type="search"
                name="q"
                value={@search_query}
                placeholder="Search YouTube…"
                autocomplete="off"
                class="h-9 flex-1 rounded-md border border-input bg-background px-3 text-sm"
              />
              <button
                disabled={@searching}
                class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-60"
              >
                <.icon
                  name={if @searching, do: "lucide-loader-circle", else: "lucide-search"}
                  class={["size-4", @searching && "animate-spin"]}
                /> Search
              </button>
            </form>

            <div :if={@previewing} class="space-y-2">
              <div class="flex items-center justify-between">
                <p class="text-xs text-muted-foreground">Preview</p>
                <button
                  phx-click="close_preview"
                  class="text-xs text-muted-foreground hover:underline"
                >
                  close
                </button>
              </div>
              <%!-- Driven through YouTube's iframe API rather than a plain
              embed. A cross-origin iframe takes no instruction, so a bare embed
              has no volume control of its own and cannot be matched against the
              theme player -- which is the comparison this page exists to make. --%>
              <div
                id={"yt-#{@previewing}"}
                phx-hook=".YouTubePreview"
                data-video-id={@previewing}
                class="max-w-2xl space-y-2"
              >
                <div class="aspect-video w-full overflow-hidden rounded-md border border-border bg-black">
                  <div data-player class="size-full"></div>
                </div>

                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    data-mute
                    aria-label="Mute"
                    class="shrink-0 rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-accent-foreground"
                  >
                    <span data-icon="unmuted"><.icon name="lucide-volume-2" class="size-4" /></span>
                    <span data-icon="muted" class="hidden">
                      <.icon name="lucide-volume-x" class="size-4" />
                    </span>
                  </button>
                  <input
                    type="range"
                    data-volume
                    min="0"
                    max="1"
                    step="0.01"
                    aria-label="Volume"
                    class="h-1.5 w-32 cursor-pointer accent-primary"
                  />
                  <span class="text-xs text-muted-foreground">
                    shared with the player above
                  </span>
                </div>
              </div>

              <script :type={Phoenix.LiveView.ColocatedHook} name=".YouTubePreview">
                // The API script is global and single-shot: it calls one global
                // callback when it loads, so the load is shared by every mount
                // rather than each one racing to define that callback.
                let apiPromise = null

                const loadApi = () => {
                  if (window.YT && window.YT.Player) return Promise.resolve()

                  if (!apiPromise) {
                    apiPromise = new Promise((resolve) => {
                      const previous = window.onYouTubeIframeAPIReady
                      window.onYouTubeIframeAPIReady = () => {
                        if (previous) { previous() }
                        resolve()
                      }
                      const tag = document.createElement("script")
                      tag.src = "https://www.youtube.com/iframe_api"
                      document.head.appendChild(tag)
                    })
                  }

                  return apiPromise
                }

                export default {
                  mounted() {
                    const el = this.el
                    const store = window.Fanfarr.volume
                    const slider = el.querySelector("[data-volume]")
                    const unmuted = el.querySelector('[data-icon="unmuted"]')
                    const muted = el.querySelector('[data-icon="muted"]')

                    loadApi().then(() => {
                      // Destroyed while the API was loading: a player built now
                      // would attach to a node that is no longer on the page and
                      // keep playing.
                      if (this.gone) return

                      this.player = new YT.Player(el.querySelector("[data-player]"), {
                        videoId: el.dataset.videoId,
                        host: "https://www.youtube-nocookie.com",
                        playerVars: {autoplay: 1, rel: 0},
                        events: {
                          onReady: () => this.applyVolume(store.level(), store.muted())
                        }
                      })
                    })

                    this.applyVolume = (level, isMuted) => {
                      slider.value = level
                      unmuted.classList.toggle("hidden", isMuted)
                      muted.classList.toggle("hidden", !isMuted)

                      // Before onReady the player object exists without its
                      // methods, so this is asked rather than assumed.
                      if (!this.player || !this.player.setVolume) return
                      this.player.setVolume(Math.round(level * 100))
                      if (isMuted) { this.player.mute() } else { this.player.unMute() }
                    }

                    this.unsubscribe = store.subscribe(({level, muted}) => {
                      this.applyVolume(level, muted)
                    })

                    slider.addEventListener("input", () => {
                      store.set({level: Number(slider.value), muted: false})
                    })

                    el.querySelector("[data-mute]").addEventListener("click", () => {
                      store.set({muted: !store.muted()})
                    })
                  },

                  destroyed() {
                    this.gone = true
                    if (this.unsubscribe) { this.unsubscribe() }
                    if (this.player && this.player.destroy) { this.player.destroy() }
                  }
                }
              </script>
            </div>

            <p :if={@search_error} class="text-sm text-destructive">{@search_error}</p>

            <ul
              :if={is_list(@search_results) and @search_results != []}
              class="divide-y divide-border/60"
            >
              <li :for={hit <- @search_results} class="flex items-center gap-3 py-2">
                <img
                  :if={hit.thumbnail}
                  src={hit.thumbnail}
                  alt=""
                  loading="lazy"
                  class="h-12 w-20 shrink-0 rounded bg-muted object-cover"
                />
                <div :if={!hit.thumbnail} class="h-12 w-20 shrink-0 rounded bg-muted" />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium" title={hit.title}>{hit.title}</p>
                  <p class="text-xs text-muted-foreground">
                    <span :if={hit.channel}>{hit.channel} · </span>
                    <span :if={hit.duration}>{duration(hit.duration)}</span>
                    <span :if={hit.view_count}> · {views(hit.view_count)}</span>
                  </p>
                </div>
                <button
                  phx-click="preview_video"
                  phx-value-id={hit.id}
                  class="inline-flex h-8 items-center gap-1 rounded-md border border-border px-2 text-xs hover:bg-accent hover:text-accent-foreground"
                >
                  <.icon name="lucide-play" class="size-3.5" /> Play
                </button>
                <button
                  phx-click="use_video"
                  phx-value-url={hit.url}
                  phx-value-title={hit.title}
                  class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-2 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                >
                  <.icon name="lucide-check" class="size-3.5" /> Use this
                </button>
              </li>
            </ul>
            <p
              :if={@search_results == [] and is_nil(@search_error)}
              class="text-sm text-muted-foreground"
            >
              No results.
            </p>

            <form
              id="theme-url"
              phx-submit="use_url"
              class="flex gap-2 border-t border-border/60 pt-4"
            >
              <input
                type="url"
                name="url"
                placeholder="…or paste a YouTube URL"
                class="h-9 flex-1 rounded-md border border-input bg-background px-3 font-mono text-xs"
              />
              <button class="h-9 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground">
                Use URL
              </button>
            </form>
          </div>
        </section>

        <section class="rounded-lg border border-border bg-card">
          <div class="border-b border-border px-4 py-3">
            <h2 class="text-sm font-semibold text-card-foreground">History</h2>
            <p class="text-xs text-muted-foreground">
              Every application attempt, permanently. Uploads cannot be undone through Plex's API,
              so this log is the record of what was done.
            </p>
          </div>
          <div :if={@history == []} class="px-4 py-6 text-sm text-muted-foreground">
            No applications yet.
          </div>
          <div :if={@history != []} class="overflow-x-auto">
            <table class="w-full text-sm">
              <tbody>
                <tr :for={entry <- @history} class="border-b border-border/60 last:border-0">
                  <td class="px-4 py-2 text-xs text-muted-foreground whitespace-nowrap">
                    {Calendar.strftime(entry.attempted_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td class="px-2 py-2">
                    <span class={[
                      "rounded-full px-2 py-0.5 text-xs font-medium",
                      entry.status == :succeeded &&
                        "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
                      entry.status == :failed && "bg-destructive/15 text-destructive",
                      entry.status == :pending && "bg-muted text-muted-foreground",
                      entry.status == :skipped && "bg-muted text-muted-foreground"
                    ]}>
                      {entry.status}
                    </span>
                    <span
                      :if={entry.dry_run}
                      class="ml-1 rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                    >
                      dry run
                    </span>
                  </td>
                  <td class="max-w-md px-2 py-2 text-xs text-muted-foreground">
                    {entry.source} · {entry.method}
                    <span
                      :if={entry.destination_path}
                      class="block break-all font-mono"
                      title={entry.destination_path}
                    >
                      {entry.destination_path}
                    </span>
                  </td>
                  <td class="px-2 py-2 text-xs text-destructive">{entry.error}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp apply_title(%{theme_locked: true}), do: "This item's theme is locked in Plex"
  defp apply_title(_), do: "Download the theme and write theme.mp3 next to the media"

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp duration(seconds) when is_number(seconds) do
    total = trunc(seconds)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp views(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M views"
  defp views(n) when n >= 1_000, do: "#{div(n, 1_000)}K views"
  defp views(n), do: "#{n} views"

  # "yes" is not a useful answer here. A title carrying Plex's own stock theme
  # looks identical to one someone chose on purpose, and telling those apart is
  # the reason this page exists.
  defp theme_origin_label(%{plex_theme_url: url}) when url in [nil, ""], do: "none"

  defp theme_origin_label(%{plex_theme_origin: :plex_agent} = item) do
    case item.plex_theme_agent do
      nil -> "yes — Plex default"
      agent -> "yes — Plex default (#{agent})"
    end
  end

  defp theme_origin_label(%{plex_theme_origin: :uploaded}), do: "yes — uploaded"
  defp theme_origin_label(_item), do: "yes — origin unknown"
end
