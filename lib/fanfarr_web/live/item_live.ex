defmodule FanfarrWeb.ItemLive.Show do
  @moduledoc """
  One show or movie: its status, what ThemerrDB knows about it, and the full
  application history. The history matters more here than anywhere -- uploads
  are irreversible, so this page is where "what did Fanfarr do to this item"
  gets answered.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  import FanfarrWeb.LibraryLive.Index, only: [status_badge: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    item = Fanfarr.Library.get_media_item!(id, load: [:theme_status, :section])

    {:ok,
     socket
     |> assign(:item, item)
     |> assign(:history, Fanfarr.Themes.theme_history_for_item!(item.id))
     |> assign(:themerr, themerr_entry(item))
     |> assign(:page_title, item.title)}
  end

  defp themerr_entry(item) do
    item_type = if item.kind == :show, do: :tv_shows, else: :movies

    ids =
      [imdb: item.imdb_id, themoviedb: item.tmdb_id]
      |> Enum.filter(fn {_db, id} -> id not in [nil, ""] end)

    Enum.find_value(ids, fn {db, id} ->
      Fanfarr.Themes.ThemerrEntry
      |> Ash.Query.filter(item_type == ^item_type and database == ^db and external_id == ^id)
      |> Ash.read_one!(authorize?: false)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={:library} current_user={@current_user}>
      <div class="space-y-6">
        <div class="flex items-start justify-between">
          <div>
            <.link navigate={~p"/"} class="text-sm text-muted-foreground hover:text-foreground">
              ← Library
            </.link>
            <h1 class="mt-1 text-2xl font-semibold tracking-tight">
              {@item.title}
              <span :if={@item.year} class="ml-1 font-normal text-muted-foreground">({@item.year})</span>
            </h1>
            <p class="mt-1 text-sm text-muted-foreground">
              {if @item.kind == :show, do: "Series", else: "Movie"}
              <span :if={@item.section}> · {@item.section.title}</span>
            </p>
          </div>
          <.status_badge status={@item.theme_status} />
        </div>

        <div class="grid gap-4 lg:grid-cols-2">
          <section class="rounded-lg border border-border bg-card p-4">
            <h2 class="text-sm font-semibold text-card-foreground">Plex</h2>
            <dl class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Reported path</dt>
                <dd class="truncate font-mono text-xs">{@item.plex_path || "—"}</dd>
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
                <dd class="font-mono text-xs">
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
              Not looked up yet. Runs as part of the theme refresh job.
            </div>
            <dl :if={@themerr} class="mt-3 space-y-2 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">In database</dt>
                <dd>{if @themerr.found, do: "yes", else: "no"}</dd>
              </div>
              <div :if={@themerr.youtube_theme_url} class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Theme source</dt>
                <dd>
                  <a
                    href={@themerr.youtube_theme_url}
                    target="_blank"
                    rel="noopener"
                    class="text-primary hover:underline"
                  >
                    YouTube ↗
                  </a>
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-muted-foreground">Checked</dt>
                <dd>{Calendar.strftime(@themerr.fetched_at, "%Y-%m-%d %H:%M UTC")}</dd>
              </div>
            </dl>
          </section>
        </div>

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
