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

  require Ash.Query

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Themes.Downloader
  alias Fanfarr.Workers.ApplyTheme
  alias Fanfarr.Workers.LookupTheme

  @search_limit 8

  # Long enough not to hammer the database, short enough that a finished job
  # does not look stuck.
  @applying_poll 2_000

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Fanfarr.PubSub, "item:#{id}")

    socket =
      socket
      |> assign(:id, id)
      |> assign(:back_path, back_path(params))
      |> assign(:search_results, nil)
      |> assign(:search_error, nil)
      |> assign(:searching, false)
      |> assign(:previewing, nil)
      |> assign(:refreshing, false)
      |> assign(:looking_up, false)
      |> assign(:poll_scheduled, false)
      # nil when the editor is closed. A map while it is open, holding the
      # draft crop -- deliberately not persisted until Apply, because a
      # half-dragged handle surviving a reload would be the only thing on this
      # page that stages a change.
      |> assign(:trim, nil)
      |> assign(:trim_loading, false)
      |> assign(:trim_error, nil)
      |> load()
      |> track_applying()
      |> maybe_lookup()

    {:ok, assign(socket, :search_query, default_query(socket.assigns.item))}
  end

  # Where "← Library" goes. The library puts its filters, sort and page on
  # the links it makes, so returning lands on the view the item was opened
  # from rather than an unfiltered first page -- narrowing thousands of items
  # to the eleven that failed and losing them by opening one is the whole
  # point.
  #
  # Only these keys are read, and they are only ever reassembled into a query
  # string on "/library", so a hand-edited URL cannot turn this into a link to
  # somewhere else. Arriving from anywhere without them -- Activity, a
  # bookmark, a shared link -- simply goes to the library.
  @carried ~w(status kind studio collection q sort page)

  defp back_path(params) do
    query =
      params
      |> Map.take(@carried)
      |> Enum.reject(fn {_k, v} -> v in [nil, "", "all"] end)
      |> Map.new()

    if query == %{}, do: ~p"/library", else: ~p"/library?#{query}"
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
    |> Enum.find(&(&1.status == :succeeded))
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
        apply_pick(socket, url, "ThemerrDB suggestion")

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
    apply_pick(socket, url, params["title"])
  end

  def handle_event("use_url", %{"url" => url}, socket) do
    url = String.trim(url)

    if Downloader.youtube_url?(url) do
      apply_pick(socket, url, nil)
    else
      {:noreply, put_flash(socket, :error, "That is not a YouTube URL")}
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

  # Everything Plex owns about this item, re-read now: a rename, a new rating,
  # a studio or collection change, and what it is serving as a theme. Off the
  # LiveView process because it is two HTTP calls to someone's media server.
  def handle_event("refresh", _params, socket) do
    item = socket.assigns.item

    {:noreply,
     socket
     |> assign(:refreshing, true)
     |> start_async(:refresh, fn -> Fanfarr.Library.ItemRefresh.refresh(item) end)}
  end

  # Re-applying what is already pinned, from the card that shows it. The pick
  # survives a Remove, so this is the one-click way back.
  def handle_event("apply_pick", _params, socket) do
    case socket.assigns.item.manual_theme_url do
      url when is_binary(url) and url != "" ->
        apply_pick(socket, url, socket.assigns.item.manual_theme_title)

      _ ->
        {:noreply, put_flash(socket, :error, "There is no pick to apply")}
    end
  end

  # Opening the editor is what triggers source resolution, and that can mean a
  # yt-dlp round trip -- so it happens off the LiveView process and the panel
  # says it is fetching rather than the page appearing to hang.
  def handle_event("trim", _params, socket) do
    item = socket.assigns.item

    {:noreply,
     socket
     |> assign(:trim_error, nil)
     |> assign(:trim_loading, true)
     |> assign(:trim, draft(item))
     |> start_async(:trim_source, fn -> Fanfarr.Themes.EditSource.resolve(item) end)}
  end

  def handle_event("close_trim", _params, socket) do
    {:noreply, socket |> assign(:trim, nil) |> assign(:trim_error, nil)}
  end

  # One event for every control in the panel -- handles, nudges, typed fields
  # -- because they all say the same thing: here are the new points. The hook
  # owns the interaction; the server owns the numbers.
  def handle_event("trim_change", params, socket) do
    {:noreply, assign(socket, :trim, apply_change(socket.assigns.trim, params))}
  end

  def handle_event("trim_reset", _params, socket) do
    trim = socket.assigns.trim
    {:noreply, assign(socket, :trim, %{trim | start_ms: nil, end_ms: nil})}
  end

  # Trim then Apply is one action from here: the page's grammar is that
  # choosing is applying, and a "saved but not written" crop would be the only
  # state on it that means neither.
  def handle_event("apply_trim", _params, socket) do
    trim = socket.assigns.trim
    item = socket.assigns.item

    Library.set_theme_trim!(item, %{
      theme_start_ms: trim.start_ms,
      theme_end_ms: trim.end_ms,
      theme_fade_in_ms: trim.fade_in_ms,
      theme_fade_out_ms: trim.fade_out_ms
    })

    socket
    |> assign(:trim, nil)
    |> load()
    |> queue(theme_url: trim.url, flash: "Queued for writing")
  end

  def handle_event("clear_manual", _params, socket) do
    Library.set_manual_theme!(socket.assigns.item, %{
      manual_theme_url: nil,
      manual_theme_title: nil
    })

    {:noreply,
     socket |> load() |> put_flash(:info, "Manual pick cleared; ThemerrDB is the source again")}
  end

  # Choosing a theme and writing it were two steps, and the second one lived at
  # the top of the page away from the choice that needed it -- so the common
  # path was to pick something and leave without applying it. They are one
  # action now.
  #
  # The URL is passed to the worker rather than left for it to re-resolve from
  # the item. Two reasons: the job then says which theme it is for, and the
  # worker's uniqueness window is keyed on it, so picking a second video within
  # five minutes of the first is a different job rather than a duplicate that
  # gets silently dropped.
  defp apply_pick(socket, url, title) do
    Library.set_manual_theme!(socket.assigns.item, %{
      manual_theme_url: url,
      manual_theme_title: title
    })

    socket
    |> load()
    |> assign(:previewing, nil)
    |> queue(theme_url: url, flash: "Queued for writing")
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
  def handle_async(:refresh, {:ok, {:ok, _item}}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> load()
     |> put_flash(:info, "Refreshed from Plex")}
  end

  def handle_async(:refresh, {:ok, {:error, :plex_not_configured}}, socket) do
    {:noreply,
     socket |> assign(:refreshing, false) |> put_flash(:error, "Plex is not configured")}
  end

  def handle_async(:refresh, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> put_flash(:error, "Plex no longer has this item. The next library sync will remove it.")}
  end

  def handle_async(:refresh, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> put_flash(:error, "Plex refused the refresh: #{inspect(reason)}")}
  end

  def handle_async(:refresh, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> put_flash(:error, "Refresh crashed: #{inspect(reason, limit: 5)}")}
  end

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

  def handle_async(:trim_source, {:ok, {:ok, resolved}}, socket) do
    {:noreply,
     socket
     |> assign(:trim_loading, false)
     |> assign(:trim, socket.assigns.trim && %{socket.assigns.trim | url: resolved.url})}
  end

  def handle_async(:trim_source, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:trim_loading, false)
     |> assign(:trim, nil)
     |> assign(:trim_error, trim_error(reason))}
  end

  def handle_async(:trim_source, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:trim_loading, false)
     |> assign(:trim, nil)
     |> assign(:trim_error, trim_error(reason))}
  end

  # Relative, because "when did Fanfarr last look" is the question the Refresh
  # button raises and a timestamp is a worse answer to it.
  defp last_synced(nil), do: "never"

  defp last_synced(at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp search_error(:not_installed),
    do: "yt-dlp is not installed in this container, so search is unavailable. See System."

  defp search_error(:timeout), do: "YouTube did not answer in time"
  defp search_error({:exit, _code, out}), do: "yt-dlp failed: #{out}"
  defp search_error(other), do: "Search failed: #{inspect(other)}"

  defp apply_trim_label(_trim, true), do: "Working…"

  defp apply_trim_label(%{start_ms: nil, end_ms: nil}, _applying), do: "Apply theme"

  defp apply_trim_label(%{start_ms: start, end_ms: finish}, _applying) do
    case finish && finish - (start || 0) do
      nil -> "Apply trimmed theme"
      ms -> "Apply trimmed theme (#{clock(ms)})"
    end
  end

  defp clock(ms) do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{String.pad_leading("#{rem(total, 60)}", 2, "0")}"
  end

  defp trim_error(:no_theme_url), do: "There is no theme chosen for this item yet."
  defp trim_error(:unavailable), do: "The video is no longer available on YouTube."
  defp trim_error(:not_installed), do: "yt-dlp is not installed, so the source cannot be fetched."
  defp trim_error(reason), do: "Could not load the audio to trim: #{inspect(reason)}"

  # The draft starts from what is already stored, so re-opening the editor
  # shows the crop that is on disk rather than a blank slate.
  defp draft(item) do
    %{
      url: nil,
      start_ms: item.theme_start_ms,
      end_ms: item.theme_end_ms,
      fade_in_ms: item.theme_fade_in_ms,
      fade_out_ms: item.theme_fade_out_ms,
      duration_ms: nil
    }
  end

  # Everything arrives as a string from the DOM. An unparseable value leaves
  # the field alone rather than resetting it to zero, which is what a half-typed
  # "1:2" would otherwise do on every keystroke.
  defp apply_change(nil, _params), do: nil

  defp apply_change(trim, params) do
    trim
    |> put_ms(params, "start_ms")
    |> put_ms(params, "end_ms")
    |> put_ms(params, "fade_in_ms")
    |> put_ms(params, "fade_out_ms")
    |> put_ms(params, "duration_ms")
    |> sane()
  end

  defp put_ms(trim, params, field) do
    case Map.fetch(params, field) do
      {:ok, ""} -> Map.put(trim, String.to_existing_atom(field), nil)
      {:ok, raw} -> maybe_put_int(trim, String.to_existing_atom(field), raw)
      :error -> trim
    end
  end

  defp maybe_put_int(trim, key, raw) do
    case Integer.parse(to_string(raw)) do
      {value, _rest} when value >= 0 -> Map.put(trim, key, value)
      _ -> trim
    end
  end

  # The server is the last word on whether the numbers make sense, because the
  # hook is not the only thing that can send them.
  defp sane(trim) do
    trim
    |> clamp_to_duration()
    |> then(fn t ->
      if is_integer(t.start_ms) and is_integer(t.end_ms) and t.end_ms <= t.start_ms do
        %{t | end_ms: nil}
      else
        t
      end
    end)
  end

  defp clamp_to_duration(%{duration_ms: nil} = trim), do: trim

  defp clamp_to_duration(%{duration_ms: duration} = trim) do
    %{
      trim
      | start_ms: trim.start_ms && min(trim.start_ms, duration),
        end_ms: trim.end_ms && min(trim.end_ms, duration)
    }
  end

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
      queue={@queue}
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
            <.link
              navigate={@back_path}
              class="text-sm text-muted-foreground hover:text-foreground"
            >
              ← Library
            </.link>
            <div class="mt-1">
              <Layouts.page_header title={@item.title}>
                <:title_suffix>
                  <span :if={@item.year} class="ml-1 font-normal text-muted-foreground">
                    ({@item.year})
                  </span>
                </:title_suffix>
                <:subtitle>
                  {if @item.kind == :show, do: "Series", else: "Movie"}
                  <span :if={@item.section}> · {@item.section.title}</span>
                </:subtitle>
                <:actions>
                  <.status_badge status={@item.theme_status} />
                </:actions>
              </Layouts.page_header>
            </div>

            <div class="mt-4 flex flex-wrap items-center gap-2">
              <button
                phx-click="lookup"
                class="inline-flex h-11 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground sm:h-9"
              >
                <.icon name="lucide-database" class="size-4" /> Look up ThemerrDB
              </button>
              <button
                phx-click="refresh"
                disabled={@refreshing}
                class="inline-flex h-11 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground disabled:cursor-not-allowed disabled:opacity-50 sm:h-9"
                title="Re-read this item from Plex: title, year, studio, collections, ratings and the theme it is serving"
              >
                <.icon
                  name="lucide-refresh-cw"
                  class={["size-4", @refreshing && "animate-spin"]}
                /> {if @refreshing, do: "Refreshing…", else: "Refresh"}
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
              <h2 class="text-sm font-semibold text-card-foreground">Current theme</h2>
              <p
                class="break-all font-mono text-xs text-muted-foreground"
                title={@item.local_theme_path}
              >
                {@item.local_theme_path}
              </p>
              <p :if={@written} class="mt-1 text-xs text-muted-foreground">
                <span :if={@written.bytes}>{format_bytes(@written.bytes)}</span>
                <span :if={@written.bytes && @written.codec}> · </span>
                <span :if={@written.codec}>{@written.codec}</span>
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <button
                :if={is_nil(@trim)}
                phx-click="trim"
                class="inline-flex h-10 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground sm:h-8"
                title="Choose where this theme starts and ends"
              >
                <.icon name="lucide-scissors" class="size-3.5" /> Trim
              </button>
              <button
                phx-click="remove_theme"
                class="inline-flex h-10 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs text-muted-foreground hover:border-destructive/40 hover:bg-destructive/10 hover:text-destructive sm:h-8"
                title="Delete the theme.mp3 Fanfarr wrote. Anything already uploaded into Plex itself stays -- Plex has no API to remove that."
              >
                <.icon name="lucide-trash-2" class="size-3.5" /> Remove theme
              </button>
            </div>
          </div>

          <%!-- The editor replaces the player rather than opening beside it or
          in a modal. It is the same audio and the same card, a modal is the
          worst shape this has on a phone, and the page already knows how to
          hand a subtree to JS. --%>
          <div
            :if={@trim_error}
            class="mt-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive"
          >
            {@trim_error}
          </div>

          <div :if={@trim} class="mt-3 space-y-3 rounded-md border border-border bg-background p-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <p class="text-xs font-medium">Trim theme</p>
              <button
                phx-click="close_trim"
                class="inline-flex min-h-11 items-center text-xs text-muted-foreground hover:underline sm:min-h-0"
              >
                Cancel
              </button>
            </div>

            <p :if={@trim_loading} class="flex items-center gap-2 text-xs text-muted-foreground">
              <.icon name="lucide-loader-circle" class="size-3.5 animate-spin" />
              Fetching the audio to trim… the first time for a theme this means a download.
            </p>

            <%!-- Everything below is the hook's. It draws the waveform, drags
            the handles and drives the audio; the server only ever hears the
            resulting numbers, through trim_change. --%>
            <div
              :if={!@trim_loading}
              id={"trimmer-#{@item.id}-#{@theme_version}"}
              phx-hook=".Trimmer"
              phx-update="ignore"
              data-audio={~p"/library/#{@item.id}/edit-source"}
              data-peaks={~p"/library/#{@item.id}/edit-peaks"}
              data-start={@trim.start_ms}
              data-end={@trim.end_ms}
              data-fade-in={@trim.fade_in_ms}
              data-fade-out={@trim.fade_out_ms}
              class="space-y-3"
            >
              <%!-- Audacity's layout, for Audacity's reason: the ruler is a
              strip of its own above the track, so the grips that drag the
              selection are not lying on top of the audio you are trying to
              click.

              They used to be. Each handle was a 40px-wide overlay spanning the
              full height of the waveform, so any press within 20px of an edge
              grabbed a handle instead of moving the playhead -- and an
              untrimmed selection puts the two handles at the very ends, which
              made the first and last 20px of every track unreachable. Up here
              a fat target costs nothing, because there is nothing behind it to
              hit. --%>
              <div class="relative select-none">
                <div class="relative h-6 sm:h-5">
                  <canvas data-ruler class="block size-full rounded-t bg-muted/60"></canvas>
                  <div
                    :for={{edge, label} <- [{"start", "Start"}, {"end", "End"}]}
                    data-handle={edge}
                    role="slider"
                    aria-label={label}
                    aria-valuemin="0"
                    tabindex="0"
                    class="group absolute inset-y-0 -ml-4 flex w-8 cursor-ew-resize touch-none justify-center sm:-ml-3 sm:w-6"
                  >
                    <div class="h-full w-1.5 rounded-t-sm bg-primary group-focus-visible:ring-2 group-focus-visible:ring-ring">
                    </div>
                  </div>
                </div>
                <%!-- The edges continue into the waveform as hairlines painted
                on the canvas rather than as DOM sitting over it, so they can be
                seen without being in the way. --%>
                <canvas
                  data-wave
                  class="block h-24 w-full cursor-text touch-none rounded-b bg-muted/40 sm:h-28"
                ></canvas>
              </div>

              <div class="space-y-2">
                <div :for={edge <- ~w(start end)} class="flex flex-wrap items-center gap-2">
                  <span class="w-10 shrink-0 text-xs capitalize text-muted-foreground">{edge}</span>
                  <input
                    data-time={edge}
                    inputmode="numeric"
                    class="h-11 w-28 shrink-0 rounded-md border border-input bg-background px-2 text-center font-mono text-xs tabular-nums sm:h-8"
                  />
                  <%!-- Dragging finds the spot; these land on it. At 390px a
                  two-minute track is about 300ms per pixel, which no thumb can
                  place exactly. --%>
                  <div class="flex items-center gap-1">
                    <button
                      :for={step <- [-1000, -100, 100, 1000]}
                      data-nudge={edge}
                      data-step={step}
                      class="inline-flex h-11 min-w-11 items-center justify-center rounded-md border border-border px-1.5 font-mono text-[11px] hover:bg-accent hover:text-accent-foreground sm:h-8 sm:min-w-0"
                    >
                      {if step > 0, do: "+", else: ""}{Float.round(step / 1000, 1)}
                    </button>
                  </div>
                </div>

                <%!-- An action, and it sits with the numbers it rewrites. In
                the transport row, between two flags, it looked like a third
                one. --%>
                <button
                  data-reset
                  class="inline-flex min-h-11 items-center gap-1.5 text-xs text-muted-foreground hover:underline sm:min-h-0"
                >
                  <.icon name="lucide-rotate-ccw" class="size-3.5" /> Select the whole track
                </button>
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <%!-- Audacity's transport order, and the first button is the
                one this most needed. "Loop the join" deliberately started
                playback three seconds before the out point, so while it was on
                -- which was always, it defaulted to on -- there was no way
                left to simply hear the selection from its beginning. --%>
                <button
                  data-restart
                  title="Play from the start of the selection (Home)"
                  class="inline-flex h-11 items-center gap-1.5 rounded-md border border-border px-3 text-xs hover:bg-accent hover:text-accent-foreground sm:h-9"
                >
                  <.icon name="lucide-skip-back" class="size-3.5" /> From start
                </button>
                <button
                  data-play
                  title="Play or stop (Space)"
                  class="inline-flex h-11 items-center gap-1.5 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90 sm:h-9"
                >
                  <.icon name="lucide-play" class="size-3.5" data-icon="play" />
                  <.icon name="lucide-square" class="hidden size-3.5" data-icon="stop" />
                  <span data-play-label>Play</span>
                </button>
                <%!-- The seam a repeat makes. Plex plays themes round and
                round, so the instant the audio jumps from the end point back
                to the start point is heard on every pass, and it is the thing
                a trim gets wrong. This drops the playhead a few seconds short
                of the end and lets it wrap, so that instant is what you hear.

                It is an action, not a mode. As a toggle called "Loop the join"
                it was two settings wearing one label -- whether playback
                repeats, and where it starts -- which is why neither was
                clear. --%>
                <button
                  data-seam
                  title="Play the last seconds before the end point and wrap to the start point, so the seam a repeat makes can be heard"
                  class="inline-flex h-11 items-center gap-1.5 rounded-md border border-border px-3 text-xs hover:bg-accent hover:text-accent-foreground sm:h-9"
                >
                  <.icon name="lucide-repeat" class="size-3.5" /> Hear the loop
                </button>

                <%!-- A flag, so it is drawn as one. As a bordered button it
                carried its state in a faint tint that read as "hovered". --%>
                <label class="inline-flex min-h-11 items-center gap-2 text-xs sm:ml-auto sm:min-h-0">
                  <span class="text-muted-foreground">Repeat</span>
                  <button
                    data-loop
                    role="switch"
                    aria-checked="true"
                    aria-label="Repeat the selection"
                    class="group inline-flex h-6 w-11 shrink-0 cursor-pointer items-center rounded-full border-2 border-transparent bg-input transition-colors aria-checked:bg-primary"
                  >
                    <span class="pointer-events-none block size-5 rounded-full bg-background shadow-lg transition-transform group-aria-checked:translate-x-5"></span>
                  </button>
                </label>
              </div>

              <details class="text-xs text-muted-foreground">
                <summary class="min-h-11 cursor-pointer list-none sm:min-h-0">
                  <span data-summary>—</span>
                </summary>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <span :for={{edge, label} <- [{"in", "Fade in"}, {"out", "Fade out"}]}>
                    <label class="mr-1">{label}</label>
                    <input
                      data-fade={edge}
                      inputmode="numeric"
                      class="h-11 w-20 rounded-md border border-input bg-background px-2 text-center font-mono text-xs sm:h-8"
                    />
                  </span>
                  <span class="text-muted-foreground">ms</span>
                </div>
              </details>
            </div>

            <button
              :if={!@trim_loading}
              phx-click="apply_trim"
              disabled={@applying or @item.theme_locked}
              class="inline-flex h-11 w-full items-center justify-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50 sm:h-9 sm:w-auto"
              title={apply_title(@item)}
            >
              <.icon name="lucide-music" class="size-4" />
              {apply_trim_label(@trim, @applying)}
            </button>
          </div>

          <%!-- The browser's own audio controls render in its default chrome,
          which is a white bar in a dark UI and ignores the theme entirely. This
          is the same element underneath, with the controls drawn from our own
          tokens. Keyed on the theme version so a newly written file replaces
          the node rather than the browser continuing with the previous one.

          phx-update="ignore" is load-bearing, not tidiness. Everything the
          player shows is set by the hook after render and appears nowhere in
          this markup, and LiveView restores form inputs from the server on
          every patch -- so the volume slider, having no value attribute to be
          restored from, snapped back to the middle of its track. Measured, not
          reasoned: with the volume at 0.31 and a track playing, clicking "Look
          up ThemerrDB" put the slider at 0.5 while the audio stayed where it
          was. Any patch to this LiveView did it, which is why it looked
          random. The subtree is the hook's; the server only decides whether it
          exists and which file it points at. --%>
          <div
            :if={is_nil(@trim)}
            id={"theme-player-#{@theme_version}"}
            phx-hook=".AudioPlayer"
            phx-update="ignore"
            data-src={~p"/library/#{@item.id}/theme?v=#{@theme_version}"}
            class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-md border border-border bg-background px-3 py-2"
          >
            <button
              type="button"
              data-play
              aria-label="Play"
              class="inline-flex size-11 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground hover:bg-primary/90 sm:size-9"
            >
              <%!-- data-icon on the icon itself. Wrapped in a span it was a
              flex item whose height came from a line box, so the glyph sat on
              that box's baseline a pixel or so below the centre of the button.
              The icon element has an explicit size, so as the flex item it
              centres exactly. --%>
              <.icon name="lucide-play" class="size-5 sm:size-4" data-icon="play" />
              <.icon name="lucide-pause" class="hidden size-5 sm:size-4" data-icon="pause" />
            </button>

            <%!-- The seek bar gets a whole line to itself below sm, and it is
            not a nicety: on a 390px screen the five controls each held their
            width and this was the only one allowed to shrink, so it measured
            0px. A scrub bar you cannot touch is the one control here that has
            no substitute -- there is no other way to reach 1:20 of a track.

            Wide enough, the row is unchanged: order-* only reorders inside a
            flex container, so the small-screen line break comes from the
            basis, and sm: puts it back beside the time. --%>
            <div
              data-track
              role="slider"
              aria-label="Seek"
              tabindex="0"
              class="relative order-last h-6 w-full shrink-0 grow cursor-pointer rounded-full py-2 sm:order-none sm:h-2 sm:w-auto sm:basis-0 sm:py-0"
            >
              <%!-- The hit area is the parent's 24px; the bar drawn inside it
              stays 8px, so it looks the same as it did and is three times
              easier to hit. --%>
              <div class="relative h-2 w-full rounded-full bg-muted">
                <div data-fill class="absolute inset-y-0 left-0 w-0 rounded-full bg-primary"></div>
              </div>
            </div>

            <span data-time class="shrink-0 font-mono text-xs tabular-nums text-muted-foreground">
              0:00 / 0:00
            </span>

            <button
              type="button"
              data-mute
              aria-label="Mute"
              class="inline-flex size-11 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-accent-foreground sm:size-8"
            >
              <.icon name="lucide-volume-2" class="size-5 sm:size-4" data-icon="unmuted" />
              <.icon name="lucide-volume-x" class="hidden size-5 sm:size-4" data-icon="muted" />
            </button>

            <%!-- The volume slider is the one control that does have a
            substitute on a phone -- the hardware buttons -- and at 80x6px it
            was not usable anyway. Mute stays. --%>
            <input
              type="range"
              data-volume
              min="0"
              max="1"
              step="0.01"
              aria-label="Volume"
              class="hidden h-1.5 w-20 shrink-0 cursor-pointer accent-primary sm:block"
            />
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".Trimmer">
            export default {
              mounted() {
                const el = this.el
                const ms = (v) => (v === "" || v == null ? null : Number(v))

                this.state = {
                  start: ms(el.dataset.start),
                  end: ms(el.dataset.end),
                  fadeIn: ms(el.dataset.fadeIn) ?? 250,
                  fadeOut: ms(el.dataset.fadeOut) ?? 500,
                  duration: null,
                  peaks: [],
                  loop: true,
                }

                this.canvas = el.querySelector("[data-wave]")
                this.audio = new Audio(el.dataset.audio)
                this.audio.preload = "metadata"

                // Shared with the theme player and the YouTube preview, so
                // trimming does not blast at a level nothing else uses.
                this.unsubscribe = window.Fanfarr.volume.subscribe(({level, muted}) => {
                  this.audio.volume = level
                  this.audio.muted = muted
                })

                this.load()
                this.wire()
              },

              // Peaks arrive as JSON rather than being decoded here: the
              // browser would be decoding whatever container YouTube served,
              // and Safari's Opus support is not worth betting this on.
              async load() {
                try {
                  const res = await fetch(this.el.dataset.peaks, {headers: {accept: "application/json"}})
                  if (!res.ok) throw new Error(res.status)
                  const body = await res.json()
                  this.state.peaks = body.peaks || []
                  this.state.duration = body.duration_ms || null
                } catch (_e) {
                  this.state.peaks = []
                }
                this.clamp()
                this.paint()
                this.pushState()
              },

              wire() {
                const el = this.el

                // The ruler grips. Coarse by design and safe to be: nothing
                // sits behind them.
                for (const edge of ["start", "end"]) {
                  const handle = el.querySelector(`[data-handle="${edge}"]`)

                  handle.addEventListener("pointerdown", (event) => {
                    event.preventDefault()
                    handle.setPointerCapture(event.pointerId)
                    this.dragging = edge
                  })

                  handle.addEventListener("pointermove", (event) => {
                    if (this.dragging !== edge) return
                    this.set(edge, this.timeAt(event.clientX), {silent: true})
                  })

                  const release = () => {
                    if (!this.dragging) return
                    this.dragging = null
                    // Pushed on release, not on every pointermove: a drag is
                    // hundreds of events and the server only needs where it
                    // ended up.
                    this.pushState()
                  }

                  handle.addEventListener("pointerup", release)
                  handle.addEventListener("pointercancel", release)

                  handle.addEventListener("keydown", (event) => {
                    const step = event.shiftKey ? 1000 : 100
                    if (event.key === "ArrowLeft") { this.nudge(edge, -step); event.preventDefault() }
                    if (event.key === "ArrowRight") { this.nudge(edge, step); event.preventDefault() }
                  })
                }

                // The waveform itself, with Audacity's three gestures on one
                // surface: press and drag out a selection, press and release
                // without moving to put the playhead there, or press within a
                // few pixels of an edge to drag that edge. Shift-click extends
                // the nearer edge to the click, as it does there too.
                //
                // Which one you get is decided at pointerdown by proximity, so
                // the grab zone can be small enough to leave the rest of the
                // surface clickable -- the whole point of moving the generous
                // target up into the ruler.
                this.canvas.addEventListener("pointerdown", (event) => {
                  if (event.button > 0) return
                  event.preventDefault()
                  this.canvas.setPointerCapture(event.pointerId)

                  const at = this.timeAt(event.clientX)
                  const {start, end} = this.bounds()

                  if (event.shiftKey && this.state.duration) {
                    const edge = Math.abs(at - start) <= Math.abs(at - end) ? "start" : "end"
                    // moved, so releasing without a drag keeps the extend
                    // rather than falling through to a seek.
                    this.gesture = {kind: "edge", edge, moved: true}
                    this.set(edge, at, {silent: true})
                    return
                  }

                  const edge = this.edgeNear(event.clientX, this.grabPx(event))
                  this.gesture = edge
                    ? {kind: "edge", edge, anchor: at, moved: false}
                    : {kind: "pending", anchor: at, x: event.clientX}
                })

                this.canvas.addEventListener("pointermove", (event) => {
                  if (!this.gesture) {
                    this.canvas.style.cursor =
                      this.edgeNear(event.clientX, this.grabPx(event)) ? "ew-resize" : "text"
                    return
                  }

                  // A press only becomes a drag once it has actually moved.
                  // Without the slop a click with a twitch in it selects four
                  // milliseconds of audio instead of moving the playhead.
                  if (this.gesture.kind === "pending") {
                    if (Math.abs(event.clientX - this.gesture.x) < 4) return
                    this.gesture = {kind: "range", anchor: this.gesture.anchor}
                  }

                  if (this.gesture.kind === "range") {
                    this.setRange(this.gesture.anchor, this.timeAt(event.clientX), {silent: true})
                  } else {
                    this.gesture.moved = true
                    this.set(this.gesture.edge, this.timeAt(event.clientX), {silent: true})
                  }
                })

                const settle = () => {
                  const gesture = this.gesture
                  if (!gesture) return
                  this.gesture = null

                  // Any press that never moved is a seek -- including one
                  // that landed inside an edge's grab zone and so was being
                  // treated as a drag of that edge. Without this the six
                  // pixels either side of each edge would still be the one
                  // place the playhead could not be put, which is the whole
                  // complaint, just smaller. Measured: a click 3px from the
                  // left of an untrimmed track left the playhead where it was.
                  if (gesture.kind === "pending" || !gesture.moved) {
                    this.seek(gesture.anchor)
                    return
                  }

                  this.pushState()
                }

                this.canvas.addEventListener("pointerup", settle)
                this.canvas.addEventListener("pointercancel", settle)

                el.querySelectorAll("[data-nudge]").forEach((button) => {
                  button.addEventListener("click", () => {
                    this.nudge(button.dataset.nudge, Number(button.dataset.step))
                  })
                })

                for (const edge of ["start", "end"]) {
                  const input = el.querySelector(`[data-time="${edge}"]`)

                  input.addEventListener("change", () => {
                    const parsed = this.parseClock(input.value)
                    if (parsed === null) { this.paint(); return }
                    this.set(edge, parsed)
                  })
                }

                el.querySelectorAll("[data-fade]").forEach((input) => {
                  input.addEventListener("change", () => {
                    const value = Math.max(0, Math.min(10000, Number(input.value) || 0))
                    this.state[input.dataset.fade === "in" ? "fadeIn" : "fadeOut"] = value
                    this.paint()
                    this.pushState()
                  })
                })

                el.querySelector("[data-play]").addEventListener("click", () => {
                  if (!this.audio.paused) { this.stop(); return }
                  this.playSelection()
                })

                el.querySelector("[data-restart]").addEventListener("click", () => {
                  this.playFrom(this.bounds().start)
                })

                el.querySelector("[data-seam]").addEventListener("click", () => this.playSeam())

                const loop = el.querySelector("[data-loop]")
                loop.addEventListener("click", () => {
                  this.state.loop = !this.state.loop
                  loop.setAttribute("aria-checked", String(this.state.loop))
                })

                el.querySelector("[data-reset]").addEventListener("click", () => {
                  this.state.start = null
                  this.state.end = null
                  this.paint()
                  this.pushState()
                })

                // Audacity's keys. The bracket pair is free -- the playhead is
                // already where you were listening -- and Space and Home are
                // the two every editor has.
                //
                // BUTTON and SUMMARY are excluded along with the text fields
                // because Space activates a focused one, and swallowing that
                // would break every control in this panel for anyone driving
                // it from the keyboard.
                this.onKey = (event) => {
                  const tag = event.target.tagName
                  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "BUTTON" || tag === "SUMMARY") return

                  const at = Math.round(this.audio.currentTime * 1000)
                  if (event.key === "[") { this.set("start", at); return }
                  if (event.key === "]") { this.set("end", at); return }

                  if (event.key === " ") {
                    event.preventDefault()
                    if (this.audio.paused) this.playSelection(); else this.stop()
                    return
                  }

                  if (event.key === "Home") {
                    event.preventDefault()
                    this.playFrom(this.bounds().start)
                  }
                }
                window.addEventListener("keydown", this.onKey)

                this.audio.addEventListener("loadedmetadata", () => {
                  if (isFinite(this.audio.duration)) {
                    this.state.duration = Math.round(this.audio.duration * 1000)
                    this.clamp()
                    this.paint()
                    this.pushState()
                  }
                })

                this.audio.addEventListener("play", () => { this.paintPlaying(true); this.follow() })
                this.audio.addEventListener("pause", () => { this.paintPlaying(false); this.paint() })

                this.repaint = () => this.paint()
                window.addEventListener("resize", this.repaint)
              },

              // --- playback --------------------------------------------------

              // From the playhead when it is already inside the selection,
              // from the in point otherwise. That is Audacity's rule, and it
              // is what makes clicking the waveform and pressing Space mean
              // "listen from here".
              playSelection() {
                const {start, end} = this.bounds()
                const at = this.audio.currentTime * 1000
                this.playFrom(at > start + 50 && at < end - 50 ? at : start)
              },

              playFrom(ms) {
                const {start, end} = this.bounds()
                this.wrapOnce = false
                this.audio.currentTime = Math.min(Math.max(ms, start), Math.max(start, end - 50)) / 1000
                this.audio.play().catch(() => this.paintPlaying(false))
              },

              // Three seconds is long enough to hear the phrase running into
              // the join without making you wait for it. wrapOnce is set after
              // playFrom has cleared it, so the seam is audible even with
              // Repeat off -- otherwise the one control whose entire purpose
              // is the wrap would stop at it.
              playSeam() {
                const {start, end} = this.bounds()
                this.playFrom(Math.max(start, end - 3000))
                this.wrapOnce = true
              },

              seek(ms) {
                const duration = this.state.duration || 0
                this.audio.currentTime = Math.min(Math.max(ms, 0), duration) / 1000
                this.paint()
              },

              stop() {
                this.audio.pause()
              },

              // The out point used to be enforced from timeupdate, which fires
              // about four times a second -- so a loop overshot its end point
              // by up to 250ms, and on a tight trim that overshoot is the
              // whole of the bit being trimmed off. A frame callback checks it
              // every 16ms and draws a playhead that moves instead of hopping.
              follow() {
                cancelAnimationFrame(this.frame)
                const step = () => {
                  if (this.audio.paused) return
                  this.boundary()
                  this.paint()
                  this.frame = requestAnimationFrame(step)
                }
                this.frame = requestAnimationFrame(step)
              },

              boundary() {
                const {start, end} = this.bounds()
                if (this.audio.currentTime * 1000 < end) return

                if (this.state.loop || this.wrapOnce) {
                  this.wrapOnce = false
                  this.audio.currentTime = start / 1000
                } else {
                  this.audio.pause()
                  this.audio.currentTime = start / 1000
                }
              },

              // --- state -----------------------------------------------------

              bounds() {
                const duration = this.state.duration || 0
                return {
                  start: this.state.start ?? 0,
                  end: this.state.end ?? duration,
                }
              },

              set(edge, value, opts = {}) {
                const duration = this.state.duration || 0
                let at = Math.max(0, Math.min(Math.round(value), duration))

                // The handles cannot cross. Half a second of minimum length,
                // because a zero-length selection renders to silence and the
                // failure is only audible after it has been written.
                if (edge === "start") {
                  const ceiling = (this.state.end ?? duration) - 500
                  this.state.start = Math.min(at, Math.max(0, ceiling))
                } else {
                  const floor = (this.state.start ?? 0) + 500
                  this.state.end = Math.max(at, Math.min(floor, duration))
                }

                this.paint()
                if (!opts.silent) this.pushState()
              },

              // Dragging out a fresh selection sets both edges at once, so it
              // cannot go through set/2 -- which exists to stop one edge
              // crossing the other and would fight an anchor being dragged
              // past its own start point.
              setRange(a, b, opts = {}) {
                const duration = this.state.duration || 0
                let lo = Math.max(0, Math.min(Math.round(Math.min(a, b)), duration))
                let hi = Math.max(0, Math.min(Math.round(Math.max(a, b)), duration))

                // The same half-second floor the edges have: a shorter
                // selection renders to something indistinguishable from
                // silence, and that only becomes audible once it is written.
                if (hi - lo < 500) {
                  hi = Math.min(duration, lo + 500)
                  lo = Math.max(0, hi - 500)
                }

                this.state.start = lo
                this.state.end = hi

                this.paint()
                if (!opts.silent) this.pushState()
              },

              // Small on purpose. This surface's first job is seeking, and
              // every pixel spent on an edge is a pixel the playhead cannot
              // reach -- which is exactly what went wrong when the grab zone
              // was 20px either side and spanned the full height. Coarse
              // pointers get a little more, and the ruler grip above is the
              // real target for both.
              grabPx(event) {
                return event.pointerType === "mouse" ? 6 : 10
              },

              edgeNear(clientX, limit) {
                const duration = this.state.duration || 0
                if (!duration) return null

                const box = this.canvas.getBoundingClientRect()
                const x = clientX - box.left
                const {start, end} = this.bounds()
                const at = (ms) => (ms / duration) * box.width

                const toStart = Math.abs(at(start) - x)
                const toEnd = Math.abs(at(end) - x)
                if (Math.min(toStart, toEnd) > limit) return null

                return toStart <= toEnd ? "start" : "end"
              },

              nudge(edge, step) {
                const current = edge === "start" ? (this.state.start ?? 0) : (this.state.end ?? this.state.duration ?? 0)
                this.set(edge, current + step)
              },

              clamp() {
                const duration = this.state.duration
                if (!duration) return
                if (this.state.start != null) this.state.start = Math.min(this.state.start, duration)
                if (this.state.end != null) this.state.end = Math.min(this.state.end, duration)
              },

              pushState() {
                this.pushEvent("trim_change", {
                  start_ms: this.state.start == null ? "" : String(this.state.start),
                  end_ms: this.state.end == null ? "" : String(this.state.end),
                  fade_in_ms: String(this.state.fadeIn),
                  fade_out_ms: String(this.state.fadeOut),
                  duration_ms: this.state.duration == null ? "" : String(this.state.duration),
                })
              },

              // --- drawing ---------------------------------------------------

              timeAt(clientX) {
                const box = this.canvas.getBoundingClientRect()
                const ratio = Math.min(Math.max((clientX - box.left) / box.width, 0), 1)
                return ratio * (this.state.duration || 0)
              },

              paintPlaying(playing) {
                const label = this.el.querySelector("[data-play-label]")
                if (label) label.textContent = playing ? "Stop" : "Play"

                const swap = (name, hidden) => {
                  const icon = this.el.querySelector(`[data-icon="${name}"]`)
                  if (icon) icon.classList.toggle("hidden", hidden)
                }
                swap("play", playing)
                swap("stop", !playing)
              },

              paint() {
                const canvas = this.canvas
                const box = canvas.getBoundingClientRect()
                if (box.width === 0) return

                const dpr = window.devicePixelRatio || 1
                canvas.width = Math.round(box.width * dpr)
                canvas.height = Math.round(box.height * dpr)

                const ctx = canvas.getContext("2d")
                ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
                ctx.clearRect(0, 0, box.width, box.height)

                const styles = getComputedStyle(this.el)
                const peaks = this.state.peaks
                const duration = this.state.duration || 0
                const {start, end} = this.bounds()
                const mid = box.height / 2

                // Scaled to the file's own loudest peak. YouTube audio is
                // often mastered well below full scale -- a real one measured
                // 0.13 -- and drawn against an absolute 1.0 the waveform is a
                // flat line that shows nothing.
                const ceiling = peaks.length ? Math.max(...peaks, 0.05) : 1

                for (let x = 0; x < box.width; x++) {
                  const at = (x / box.width) * duration
                  const peak = peaks.length ? peaks[Math.min(peaks.length - 1, Math.floor((x / box.width) * peaks.length))] : 0
                  const height = Math.max(1, (peak / ceiling) * (box.height * 0.9))
                  const inside = at >= start && at <= end

                  ctx.fillStyle = inside
                    ? styles.getPropertyValue("--color-primary") || "#7c93f7"
                    : "rgba(127,127,127,0.35)"

                  ctx.fillRect(x, mid - height / 2, 1, height)
                }

                // The selection as a lit region with the rest veiled, rather
                // than only a change of bar colour. A narrow selection in a
                // busy waveform is otherwise genuinely hard to find, and the
                // edges need to read as edges now that they are no longer
                // 40px-wide objects lying on the track.
                if (duration) {
                  const sx = (start / duration) * box.width
                  const ex = (end / duration) * box.width

                  ctx.fillStyle = "rgba(127,127,127,0.18)"
                  ctx.fillRect(0, 0, sx, box.height)
                  ctx.fillRect(ex, 0, box.width - ex, box.height)

                  ctx.fillStyle = styles.getPropertyValue("--color-primary") || "#7c93f7"
                  ctx.fillRect(sx - 0.5, 0, 1, box.height)
                  ctx.fillRect(ex - 0.5, 0, 1, box.height)
                }

                // Drawn whether or not anything is playing. It used to appear
                // only during playback, so clicking to place it did nothing
                // visible and there was no way to tell where Space or "]"
                // would act from.
                if (duration) {
                  const x = (this.audio.currentTime * 1000 / duration) * box.width
                  ctx.fillStyle = styles.getPropertyValue("--color-foreground") || "#fff"
                  ctx.fillRect(x, 0, 1, box.height)
                }

                this.paintRuler()
                this.position(start, end, box.width)
                this.labels(start, end)
              },

              // Audacity's timeline, and the reason the strip is tall enough
              // to hold a grip in the first place: without numbers on it, it
              // is a bar of empty chrome asking to be given back to the
              // waveform.
              paintRuler() {
                const canvas = this.el.querySelector("[data-ruler]")
                if (!canvas) return

                const box = canvas.getBoundingClientRect()
                if (box.width === 0) return

                const dpr = window.devicePixelRatio || 1
                canvas.width = Math.round(box.width * dpr)
                canvas.height = Math.round(box.height * dpr)

                const ctx = canvas.getContext("2d")
                ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
                ctx.clearRect(0, 0, box.width, box.height)

                const duration = this.state.duration || 0
                if (!duration) return

                // The first interval that puts its labels at least 64px apart,
                // so they never collide -- at any width, on any length of
                // track, without a breakpoint deciding it.
                const steps = [1000, 5000, 10000, 15000, 30000, 60000, 120000, 300000, 600000]
                const step =
                  steps.find((ms) => (ms / duration) * box.width >= 64) || steps[steps.length - 1]

                ctx.fillStyle = "rgba(127,127,127,0.85)"
                ctx.font = "10px ui-monospace, SFMono-Regular, Menlo, monospace"
                ctx.textBaseline = "middle"

                for (let at = 0; at <= duration; at += step) {
                  const x = (at / duration) * box.width
                  ctx.fillRect(x, box.height - 4, 1, 4)

                  const label = this.clock(at).replace(/\.\d$/, "")
                  if (x + ctx.measureText(label).width + 4 < box.width) {
                    ctx.fillText(label, x + 3, box.height / 2 - 1)
                  }
                }
              },

              position(start, end, width) {
                const duration = this.state.duration || 1
                const place = (edge, at) => {
                  const handle = this.el.querySelector(`[data-handle="${edge}"]`)
                  if (!handle) return
                  handle.style.left = `${(at / duration) * width}px`
                  handle.setAttribute("aria-valuenow", String(Math.round(at)))
                  handle.setAttribute("aria-valuemax", String(Math.round(duration)))
                  handle.setAttribute("aria-valuetext", this.clock(at))
                }
                place("start", start)
                place("end", end)
              },

              labels(start, end) {
                const set = (selector, value) => {
                  const node = this.el.querySelector(selector)
                  if (node && node !== document.activeElement) node.value = value
                }
                set('[data-time="start"]', this.clock(start))
                set('[data-time="end"]', this.clock(end))
                set('[data-fade="in"]', String(this.state.fadeIn))
                set('[data-fade="out"]', String(this.state.fadeOut))

                const summary = this.el.querySelector("[data-summary]")
                if (summary) {
                  summary.textContent =
                    `${this.clock(end - start)} selected · fades ${this.state.fadeIn}ms / ${this.state.fadeOut}ms`
                }
              },

              clock(ms) {
                const total = Math.max(0, ms) / 1000
                const minutes = Math.floor(total / 60)
                const seconds = (total - minutes * 60).toFixed(1).padStart(4, "0")
                return `${minutes}:${seconds}`
              },

              // "1:23.4", "83.4" and "83" all mean the same thing; anything
              // else leaves the field alone rather than becoming zero.
              parseClock(raw) {
                const text = String(raw).trim()
                if (!text) return null

                const parts = text.split(":")
                const seconds = Number(parts.pop())
                if (!isFinite(seconds)) return null

                const minutes = parts.length ? Number(parts.pop()) : 0
                if (!isFinite(minutes)) return null

                return Math.round((minutes * 60 + seconds) * 1000)
              },

              destroyed() {
                cancelAnimationFrame(this.frame)
                window.removeEventListener("keydown", this.onKey)
                window.removeEventListener("resize", this.repaint)
                if (this.unsubscribe) this.unsubscribe()
                if (this.audio) { this.audio.pause(); this.audio.src = "" }
              }
            }
          </script>
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

                // Derived from the element, never from what we think we just
                // did to it. The button had two ways to end up lying: play()
                // is a promise, so a rejected one (a file that will not load,
                // a policy that blocks playback) left the icon on "pause" over
                // an element that never started; and a second click landing
                // before the first click's "play" event arrived processed the
                // events out of order. Re-reading audio.paused has neither
                // failure mode, and is cheap enough to do on every event.
                const sync = () => {
                  const playing = !audio.paused
                  playIcon.classList.toggle("hidden", playing)
                  pauseIcon.classList.toggle("hidden", !playing)
                  playButton.setAttribute("aria-label", playing ? "Pause" : "Play")
                }

                playButton.addEventListener("click", () => {
                  if (audio.paused) { audio.play().catch(sync) } else { audio.pause() }
                  // Immediately, not on the event: play() flips audio.paused
                  // synchronously but the event arrives later, and on a cold
                  // file that gap is long enough to look like a dead button.
                  sync()
                })

                el.querySelector("[data-mute]").addEventListener("click", () => {
                  window.Fanfarr.volume.set({muted: !audio.muted})
                })

                track.addEventListener("click", (event) => {
                  const box = track.getBoundingClientRect()
                  const ratio = Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1)
                  if (isFinite(audio.duration)) { audio.currentTime = ratio * audio.duration }
                })

                audio.addEventListener("play", sync)
                audio.addEventListener("playing", sync)
                audio.addEventListener("pause", sync)
                audio.addEventListener("ended", () => { sync(); paint() })
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
        </section>

        <%!-- grid-cols-1 is not redundant with the implicit single column.
        Tailwind's grid-cols-* expand to repeat(n, minmax(0, 1fr)), and it is
        the minmax(0, ...) that lets a track go narrower than its content:
        an implicit auto track keeps a grid item's min-width: auto floor, so
        these three cards each measured 337px inside a 302px column and the
        page carried the difference. --%>
        <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <section class="rounded-lg border border-border bg-card p-4">
            <h2 class="text-sm font-semibold text-card-foreground">Plex</h2>
            <dl class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Reported path</dt>
                <%!-- min-w-0, or the nowrap from `truncate` makes this path's
                full length the row's floor and the card outgrows the screen. --%>
                <dd class="min-w-0 truncate font-mono text-xs" title={@item.plex_path}>
                  {@item.plex_path || "—"}
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Theme on server</dt>
                <dd class="text-right">{theme_origin_label(@item)}</dd>
              </div>
              <%!-- Studio and collection are the two fields on this card that
              describe a *set* rather than this item, and the question they
              raise is always "what else is in it". Both are library filters
              already, so they link to that filtered library rather than making
              the reader retype the name into a dropdown. --%>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Studio</dt>
                <dd class="text-right">
                  <.link
                    :if={@item.studio not in [nil, ""]}
                    navigate={~p"/library?#{%{"studio" => @item.studio}}"}
                    class="underline decoration-dotted underline-offset-4 hover:text-primary"
                    title={"Everything from #{@item.studio}"}
                  >
                    {@item.studio}
                  </.link>
                  <span :if={@item.studio in [nil, ""]}>—</span>
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Collections</dt>
                <dd class="text-right">
                  <span :if={@item.collections == []}>—</span>
                  <%!-- The comma is glued to the link it follows, with the word
                  space between the outer spans. A separator rendered as its own
                  sibling picks up HEEx's whitespace on both sides and reads
                  "Batman Collection , DC Universe". --%>
                  <span :for={{collection, index} <- Enum.with_index(@item.collections)}>
                    <.link
                      navigate={~p"/library?#{%{"collection" => collection}}"}
                      class="underline decoration-dotted underline-offset-4 hover:text-primary"
                      title={"Everything in #{collection}"}
                    >{collection}</.link><span :if={index < length(@item.collections) - 1}>,</span>
                  </span>
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Critics</dt>
                <dd class="text-right" title={Fanfarr.Library.Score.label(@item.critic_score_source)}>
                  {Fanfarr.Library.Score.format(@item.critic_score) || "—"}
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Audience</dt>
                <dd
                  class="text-right"
                  title={Fanfarr.Library.Score.label(@item.audience_score_source)}
                >
                  {Fanfarr.Library.Score.format(@item.audience_score) || "—"}
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Theme locked</dt>
                <dd>{if @item.theme_locked, do: "yes", else: "no"}</dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Last read from Plex</dt>
                <dd class="text-right">{last_synced(@item.last_synced_at)}</dd>
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
                <dd title={Fanfarr.Clock.precise(@themerr.fetched_at)}>
                  {Fanfarr.Clock.ago(@themerr.fetched_at)}
                </dd>
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
                  class="inline-flex h-10 items-center gap-1 rounded-md border border-border px-3 text-xs hover:bg-accent hover:text-accent-foreground sm:h-8 sm:px-2"
                >
                  <.icon name="lucide-play" class="size-3.5" /> Preview
                </button>
                <button
                  phx-click="use_themerr"
                  disabled={@applying or @item.theme_locked}
                  class="inline-flex h-10 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50 sm:h-8 sm:px-2"
                  title={apply_title(@item)}
                >
                  <.icon name="lucide-music" class="size-3.5" />
                  {if @applying, do: "Working…", else: "Apply theme"}
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
              <%!-- The only place a pick already made can be written again.
              With the apply action moved onto the choice, a pick from a search
              run yesterday would otherwise need the search running again. --%>
              <button
                phx-click="apply_pick"
                disabled={@applying or @item.theme_locked}
                class="inline-flex h-10 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50 sm:h-8 sm:px-2"
                title={apply_title(@item)}
              >
                <.icon name="lucide-music" class="size-3.5" />
                {if @applying, do: "Working…", else: "Apply theme"}
              </button>
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
                class="h-11 min-w-0 flex-1 rounded-md border border-input bg-background px-3 text-sm sm:h-9"
              />
              <button
                disabled={@searching}
                class="inline-flex h-11 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-60 sm:h-9"
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
              <%!-- A thumbnail, a title that must not wrap, and two buttons
              are four things that do not fit across a phone. Below sm this is
              two rows -- thumbnail and title, then the actions under them,
              full width and thumb-sized. From sm it is the single line it
              always was.

              The title is `truncate`, so its min-content width is the whole
              title (nowrap). That is what took this page to 1,246px on a
              390px screen before the layout gained min-w-0; the wrapper here
              needs its own, or the title's floor propagates out of the row. --%>
              <li
                :for={hit <- @search_results}
                class="flex flex-col gap-2 py-2 sm:flex-row sm:items-center sm:gap-3"
              >
                <div class="flex min-w-0 items-center gap-3">
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
                    <p class="truncate text-xs text-muted-foreground">
                      <span :if={hit.channel}>{hit.channel} · </span>
                      <span :if={hit.duration}>{duration(hit.duration)}</span>
                      <span :if={hit.view_count}> · {views(hit.view_count)}</span>
                    </p>
                  </div>
                </div>
                <div class="flex shrink-0 items-center gap-2 pl-[5.75rem] sm:gap-3 sm:pl-0">
                  <button
                    phx-click="preview_video"
                    phx-value-id={hit.id}
                    class="inline-flex h-10 shrink-0 items-center gap-1 rounded-md border border-border px-3 text-xs hover:bg-accent hover:text-accent-foreground sm:h-8 sm:px-2"
                  >
                    <.icon name="lucide-play" class="size-3.5" /> Play
                  </button>
                  <button
                    phx-click="use_video"
                    phx-value-url={hit.url}
                    phx-value-title={hit.title}
                    disabled={@applying or @item.theme_locked}
                    class="inline-flex h-10 shrink-0 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50 sm:h-8 sm:px-2"
                    title={apply_title(@item)}
                  >
                    <.icon name="lucide-music" class="size-3.5" />
                    {if @applying, do: "Working…", else: "Apply theme"}
                  </button>
                </div>
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
                class="h-11 min-w-0 flex-1 rounded-md border border-input bg-background px-3 font-mono text-xs sm:h-9"
              />
              <button class="h-11 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground sm:h-9">
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
                    <span title={
                      "#{Fanfarr.Clock.precise(entry.attempted_at)} #{Fanfarr.Clock.offset(entry.attempted_at)}"
                    }>
                      {Fanfarr.Clock.ago(entry.attempted_at)}
                    </span>
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
