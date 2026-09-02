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

  alias Fanfarr.Library
  alias Fanfarr.Themes.Downloader
  alias Fanfarr.Workers.ApplyTheme

  @search_limit 8

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
      |> load()

    {:ok, assign(socket, :search_query, default_query(socket.assigns.item))}
  end

  defp load(socket) do
    item = Library.get_media_item!(socket.assigns.id, load: [:theme_status, :section])

    socket
    |> assign(:item, item)
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
         |> Fanfarr.Workers.LookupTheme.new()
         |> Oban.insert() do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "ThemerrDB lookup queued")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not queue the lookup")}
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

  def handle_event("clear_manual", _params, socket) do
    Library.set_manual_theme!(socket.assigns.item, %{
      manual_theme_url: nil,
      manual_theme_title: nil
    })

    {:noreply,
     socket |> load() |> put_flash(:info, "Manual pick cleared; ThemerrDB is the source again")}
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
      {:ok, _} -> {:noreply, put_flash(socket, :info, flash)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not queue the job")}
    end
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

  defp search_error(:not_installed),
    do: "yt-dlp is not installed in this container, so search is unavailable. See System."

  defp search_error(:timeout), do: "YouTube did not answer in time"
  defp search_error({:exit, _code, out}), do: "yt-dlp failed: #{out}"
  defp search_error(other), do: "Search failed: #{inspect(other)}"

  @impl true
  def handle_info({:item_updated, _id}, socket), do: {:noreply, load(socket)}

  # --- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={:library} current_user={@current_user}>
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
                class="inline-flex h-9 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground"
                title="Resolves the theme and the destination, checks it is writable, writes nothing"
              >
                <.icon name="lucide-flask-conical" class="size-4" /> Preview (dry run)
              </button>
              <button
                phx-click="apply"
                data-confirm={"Write theme.mp3 next to #{@item.title}? Deleting the file undoes it."}
                disabled={@item.theme_locked or @item.kind == :movie}
                class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
                title={apply_title(@item)}
              >
                <.icon name="lucide-music" class="size-4" /> Apply theme
              </button>
              <button
                phx-click="lookup"
                class="inline-flex h-9 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground"
              >
                <.icon name="lucide-database" class="size-4" /> Look up ThemerrDB
              </button>
            </div>
            <p :if={@item.kind == :movie} class="mt-2 text-xs text-muted-foreground">
              Applying to movies is disabled until local theme files for movies are verified against
              a real server. Previews and manual picks still work.
            </p>
          </div>
        </div>

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
            <h2 class="text-sm font-semibold text-card-foreground">ThemerrDB</h2>
            <div :if={@themerr == nil} class="mt-3 text-sm text-muted-foreground">
              Not looked up yet.
            </div>
            <dl :if={@themerr} class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">In database</dt>
                <dd>{if @themerr.found, do: "yes", else: "no"}</dd>
              </div>
              <div :if={@themerr.youtube_theme_url} class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Suggests</dt>
                <dd>
                  <button
                    :if={Downloader.youtube_id(@themerr.youtube_theme_url)}
                    phx-click="preview_video"
                    phx-value-id={Downloader.youtube_id(@themerr.youtube_theme_url)}
                    class="text-primary hover:underline"
                  >
                    play preview
                  </button>
                  <a
                    href={@themerr.youtube_theme_url}
                    target="_blank"
                    rel="noopener"
                    class="ml-2 text-muted-foreground hover:underline"
                  >
                    ↗
                  </a>
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Checked</dt>
                <dd>{Calendar.strftime(@themerr.fetched_at, "%Y-%m-%d %H:%M")}</dd>
              </div>
            </dl>
          </section>

          <section class="rounded-lg border border-border bg-card p-4">
            <h2 class="text-sm font-semibold text-card-foreground">Your pick</h2>
            <div :if={@item.manual_theme_url in [nil, ""]} class="mt-3 text-sm text-muted-foreground">
              None. ThemerrDB's suggestion is used, if it has one. Search below to choose your own.
            </div>
            <div :if={@item.manual_theme_url not in [nil, ""]} class="mt-3 space-y-2 text-sm">
              <p class="font-medium">{@item.manual_theme_title || "Chosen video"}</p>
              <p
                class="truncate font-mono text-xs text-muted-foreground"
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
              <iframe
                id={"yt-#{@previewing}"}
                src={"https://www.youtube-nocookie.com/embed/#{@previewing}?autoplay=1"}
                title="YouTube preview"
                allow="autoplay; encrypted-media; picture-in-picture"
                allowfullscreen
                class="aspect-video w-full max-w-2xl rounded-md border border-border bg-black"
              ></iframe>
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
          <table :if={@history != []} class="w-full text-sm">
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
                <td class="px-2 py-2 text-xs text-muted-foreground">
                  {entry.source} · {entry.method}
                  <span
                    :if={entry.destination_path}
                    class="block truncate font-mono"
                    title={entry.destination_path}
                  >
                    {entry.destination_path}
                  </span>
                </td>
                <td class="px-2 py-2 text-xs text-destructive">{entry.error}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp apply_title(%{theme_locked: true}), do: "This item's theme is locked in Plex"
  defp apply_title(%{kind: :movie}), do: "Movies are not supported yet"
  defp apply_title(_), do: "Download the theme and write theme.mp3 next to the media"

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
