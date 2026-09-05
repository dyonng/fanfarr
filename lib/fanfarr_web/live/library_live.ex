defmodule FanfarrWeb.LibraryLive.Index do
  @moduledoc """
  The default view: every show and movie, with theme status front and centre.

  Follows the Sonarr table register -- dense rows, status colour semantics,
  filters that narrow rather than navigate. Served entirely from the SQLite
  mirror; Plex is never queried to render this page.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias Fanfarr.Library.MediaItem

  @page_size 50

  # How many pages to show either side of the current one.
  @window 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Fanfarr.PubSub, "library")

    {:ok,
     socket
     |> assign(:selected, MapSet.new())
     |> assign(:page_title, "Library")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      status: params["status"],
      kind: params["kind"],
      studio: params["studio"],
      collection: params["collection"],
      q: params["q"],
      sort: params["sort"],
      page: max(String.to_integer(params["page"] || "1"), 1)
    }

    {:noreply, socket |> assign(:filters, filters) |> load_items()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    # Only the form's own fields: a phx-change payload also carries _target,
    # which would end up in the URL.
    overrides = Map.take(params, ["status", "kind", "studio", "collection", "q"])

    {:noreply, push_patch(socket, to: ~p"/?#{query_params(socket, overrides)}")}
  end

  def handle_event("sync", _params, socket) do
    case Fanfarr.Workers.SyncLibrary.new(%{}) |> Oban.insert() do
      {:ok, _job} -> {:noreply, put_flash(socket, :info, "Library sync queued")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not queue the sync")}
    end
  end

  # --- selection and bulk actions -------------------------------------------
  #
  # The *arr "mass edit" pattern: tick rows, act on all of them. Selection
  # lives in the socket rather than the URL, so it survives paging and filter
  # changes within a visit and is gone on reload.

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_page", _params, socket) do
    page_ids = Enum.map(socket.assigns.items, & &1.id)
    selected = socket.assigns.selected

    selected =
      if Enum.all?(page_ids, &MapSet.member?(selected, &1)),
        do: MapSet.difference(selected, MapSet.new(page_ids)),
        else: MapSet.union(selected, MapSet.new(page_ids))

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all_matching", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new(socket.assigns.all_ids))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("bulk", %{"action" => action}, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    {queued, label} =
      case action do
        "preview" -> {Enum.count(ids, &enqueue_apply(&1, dry_run: true)), "dry runs"}
        "apply" -> {Enum.count(ids, &enqueue_apply(&1, dry_run: false)), "theme writes"}
        "lookup" -> {Enum.count(ids, &enqueue_lookup/1), "ThemerrDB lookups"}
      end

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> put_flash(:info, "Queued #{queued} #{label}")}
  end

  defp enqueue_apply(id, opts), do: match?({:ok, _}, Fanfarr.Workers.ApplyTheme.enqueue(id, opts))

  defp enqueue_lookup(id) do
    match?({:ok, _}, %{media_item_id: id} |> Fanfarr.Workers.LookupTheme.new() |> Oban.insert())
  end

  @impl true
  def handle_info({:section_synced, _id}, socket) do
    {:noreply, load_items(socket)}
  end

  # Filtering happens in the query where AshSqlite supports it (kind and
  # title search); theme_status is a calculation that reads the application
  # log, so the status filter applies after load. The page is capped either
  # way, so the post-filter never scans more than one page's worth beyond need.
  defp load_items(%{assigns: %{filters: filters}} = socket) do
    query =
      MediaItem
      |> Ash.Query.load(:theme_status)
      |> Ash.Query.sort(title: :asc)

    query =
      case filters.kind do
        "show" -> Ash.Query.filter(query, kind == :show)
        "movie" -> Ash.Query.filter(query, kind == :movie)
        _ -> query
      end

    query =
      case filters.studio do
        nil -> query
        "" -> query
        "all" -> query
        studio -> Ash.Query.filter(query, studio == ^studio)
      end

    query =
      case filters.q do
        nil -> query
        "" -> query
        q -> Ash.Query.filter(query, contains(string_downcase(title), ^String.downcase(q)))
      end

    items = Ash.read!(query, authorize?: false)

    items =
      case filters.status do
        nil -> items
        "" -> items
        status -> Enum.filter(items, &(to_string(&1.theme_status) == status))
      end

    # Collections are a JSON array in SQLite, which has no native membership
    # operator worth reaching for here. Filtered after load like status is,
    # and for the same reason: the set is already in memory and one library
    # is thousands of rows, not millions.
    items =
      case filters.collection do
        nil -> items
        "" -> items
        "all" -> items
        collection -> Enum.filter(items, &(collection in &1.collections))
      end

    items = sort(items, filters.sort)

    total = length(items)
    pages = max(ceil(total / @page_size), 1)
    page = min(filters.page, pages)

    visible = Enum.slice(items, (page - 1) * @page_size, @page_size)

    socket
    |> assign(:items, visible)
    |> assign(facets())
    |> assign(:all_ids, Enum.map(items, & &1.id))
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:pages, pages)
    |> assign(:counts, Enum.frequencies_by(items, & &1.theme_status))
  end

  # What the two grouping dropdowns can offer.
  #
  # Read from the whole library rather than from the current result set: once
  # you have narrowed to Pixar, Pixar would be the only studio left to pick,
  # and the filter would be a one-way door. Its own query rather than a reuse
  # of the items above for the same reason -- that one is already filtered.
  # Two columns wide over a table the page has just read anyway.
  defp facets do
    rows =
      MediaItem
      |> Ash.Query.select([:studio, :collections])
      |> Ash.read!(authorize?: false)

    %{
      studios: rows |> Enum.map(& &1.studio) |> names(),
      collections: rows |> Enum.flat_map(& &1.collections) |> names()
    }
  end

  defp names(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  # Sorting is a link rather than an event, so it survives a reload and can be
  # shared; this only works out which link the next click should point at.
  # Clicking the column already sorted turns it round, and any other column
  # starts ascending -- descending first would be right for a score and wrong
  # for a title, and one rule that is sometimes wrong beats two to remember.
  defp sort_link(current, column) do
    case current do
      ^column -> "-" <> column
      _ -> column
    end
  end

  defp sort_indicator(current, column) do
    case current do
      ^column -> "lucide-arrow-up"
      "-" <> ^column -> "lucide-arrow-down"
      _ -> nil
    end
  end

  # Whatever is in the URL now, with the given overrides applied and the
  # empties dropped. Sorting must not clear the filters, and filtering must
  # not silently reset the sort.
  defp query_params(socket, overrides) do
    filters = socket.assigns.filters

    %{
      "status" => filters.status,
      "kind" => filters.kind,
      "studio" => filters.studio,
      "collection" => filters.collection,
      "q" => filters.q,
      "sort" => filters.sort
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> v in [nil, "", "all"] end)
    |> Map.new()
  end

  # --- sorting ----------------------------------------------------------------
  #
  # In Elixir rather than in the query, because the set is already fully
  # materialised here: the status filter is a calculation the data layer
  # cannot express, so paging happens after the fact regardless. Sorting the
  # same list keeps every column working the same way, including the two the
  # database could not sort at all.
  #
  # Enum.sort_by/3 is stable and the query arrives ordered by title, so equal
  # keys stay alphabetical instead of shuffling between renders.

  @sortable ~w(title year kind critic audience studio status)

  defp sort(items, nil), do: items

  defp sort(items, sort) do
    {column, direction} = parse_sort(sort)

    if column in @sortable do
      Enum.sort_by(items, &key(&1, column), comparator(column, direction))
    else
      items
    end
  end

  defp parse_sort("-" <> column), do: {column, :desc}
  defp parse_sort(column), do: {column, :asc}

  defp key(item, "title"), do: String.downcase(item.title || "")
  defp key(item, "year"), do: item.year
  defp key(item, "kind"), do: to_string(item.kind)
  defp key(item, "critic"), do: item.critic_score
  defp key(item, "audience"), do: item.audience_score
  # Nil rather than "" for the unattributed, so they sort last with the
  # unrated rather than first under an invisible empty string.
  defp key(item, "studio"), do: item.studio && String.downcase(item.studio)
  defp key(item, "status"), do: status_rank(item.theme_status)

  # The order the operator works down: what needs attention first, what is
  # finished last. Alphabetical would put :failed between :fanfarr_applied and
  # :local_file, which is no order at all.
  @status_order [:failed, :missing, :plex_supplied, :local_file, :fanfarr_applied]
  defp status_rank(status), do: Enum.find_index(@status_order, &(&1 == status)) || 99

  # A missing score is not a low score. Sorting nils as if they were zero puts
  # every unrated item at the top of an ascending sort, which buries the thing
  # being looked for; they sort last in both directions instead.
  defp comparator(column, direction) when column in ~w(critic audience year studio) do
    fn a, b ->
      cond do
        # Two unrated items are equal, and a stable sort keeps equal elements
        # in the order they arrived only if the comparator says so. Returning
        # false here instead reversed every run of unrated items.
        is_nil(a) and is_nil(b) -> true
        is_nil(a) -> false
        is_nil(b) -> true
        direction == :asc -> a <= b
        true -> a >= b
      end
    end
  end

  defp comparator(_column, :asc), do: &<=/2
  defp comparator(_column, :desc), do: &>=/2

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={:library}
      current_user={@current_user}
      queue={@queue}
    >
      <div class="space-y-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Library</h1>
            <p class="text-sm text-muted-foreground">
              {@total} items · {Map.get(@counts, :missing, 0)} without a theme
            </p>
          </div>
          <button
            phx-click="sync"
            class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            <.icon name="lucide-refresh-cw" class="size-4" /> Sync library
          </button>
        </div>

        <form id="library-filters" phx-change="filter" class="flex flex-wrap items-end gap-2">
          <input
            type="search"
            name="q"
            value={@filters.q}
            placeholder="Search titles…"
            phx-debounce="300"
            class="h-9 w-56 rounded-md border border-input bg-background px-3 text-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          />
          <select name="status" class="h-9 rounded-md border border-input bg-background px-2 text-sm">
            <option value="all" selected={@filters.status in [nil, "", "all"]}>Any status</option>
            <option value="missing" selected={@filters.status == "missing"}>Missing</option>
            <option value="failed" selected={@filters.status == "failed"}>Failed</option>
            <option value="plex_supplied" selected={@filters.status == "plex_supplied"}>
              Plex theme
            </option>
            <option value="fanfarr_applied" selected={@filters.status == "fanfarr_applied"}>
              Fanfarr theme
            </option>
            <option value="local_file" selected={@filters.status == "local_file"}>Local file</option>
          </select>
          <select name="kind" class="h-9 rounded-md border border-input bg-background px-2 text-sm">
            <option value="all" selected={@filters.kind in [nil, "", "all"]}>Shows & movies</option>
            <option value="show" selected={@filters.kind == "show"}>Shows</option>
            <option value="movie" selected={@filters.kind == "movie"}>Movies</option>
          </select>
          <select
            :if={@studios != []}
            name="studio"
            class="h-9 max-w-48 rounded-md border border-input bg-background px-2 text-sm"
          >
            <option value="all" selected={@filters.studio in [nil, "", "all"]}>Any studio</option>
            <option :for={studio <- @studios} value={studio} selected={@filters.studio == studio}>
              {studio}
            </option>
          </select>
          <select
            :if={@collections != []}
            name="collection"
            class="h-9 max-w-48 rounded-md border border-input bg-background px-2 text-sm"
          >
            <option value="all" selected={@filters.collection in [nil, "", "all"]}>
              Any collection
            </option>
            <option
              :for={collection <- @collections}
              value={collection}
              selected={@filters.collection == collection}
            >
              {collection}
            </option>
          </select>
        </form>

        <div :if={@items == []} class="rounded-lg border border-dashed border-border p-10 text-center">
          <p class="text-sm text-muted-foreground">
            Nothing here yet. Configure Plex under Settings, enable a library, then Sync.
          </p>
        </div>

        <div
          :if={MapSet.size(@selected) > 0}
          id="bulk-bar"
          class="flex flex-wrap items-center gap-2 rounded-lg border border-primary/40 bg-primary/5 px-3 py-2 text-sm"
        >
          <span class="font-medium">{MapSet.size(@selected)} selected</span>
          <button
            :if={MapSet.size(@selected) < @total}
            phx-click="select_all_matching"
            class="text-primary hover:underline"
          >
            select all {@total} matching
          </button>
          <span class="flex-1" />
          <button
            phx-click="bulk"
            phx-value-action="preview"
            class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border bg-background px-2.5 text-xs hover:bg-accent hover:text-accent-foreground"
          >
            <.icon name="lucide-flask-conical" class="size-3.5" /> Preview (dry run)
          </button>
          <button
            phx-click="bulk"
            phx-value-action="lookup"
            class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border bg-background px-2.5 text-xs hover:bg-accent hover:text-accent-foreground"
          >
            <.icon name="lucide-database" class="size-3.5" /> Look up ThemerrDB
          </button>
          <button
            phx-click="bulk"
            phx-value-action="apply"
            data-confirm={"Write theme.mp3 for #{MapSet.size(@selected)} items? Each file can be deleted to undo, but this is a lot of writes -- run a dry run first."}
            class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-2.5 text-xs font-medium text-primary-foreground hover:bg-primary/90"
          >
            <.icon name="lucide-music" class="size-3.5" /> Apply themes
          </button>
          <button phx-click="clear_selection" class="text-xs text-muted-foreground hover:underline">
            clear
          </button>
        </div>

        <div :if={@items != []} class="overflow-x-auto rounded-lg border border-border">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-border bg-muted/50 text-left text-xs uppercase tracking-wide text-muted-foreground">
                <th class="w-8 px-3 py-2">
                  <input
                    type="checkbox"
                    phx-click="select_page"
                    checked={@items != [] and Enum.all?(@items, &MapSet.member?(@selected, &1.id))}
                    aria-label="Select this page"
                    class="size-4 rounded border-input"
                  />
                </th>
                <th class="w-10 px-1 py-2"></th>
                <.column_header sort={@filters.sort} column="title" params={@filters}>
                  Title
                </.column_header>
                <.column_header sort={@filters.sort} column="year" params={@filters}>
                  Year
                </.column_header>
                <.column_header sort={@filters.sort} column="kind" params={@filters}>
                  Type
                </.column_header>
                <.column_header
                  sort={@filters.sort}
                  column="critic"
                  params={@filters}
                  title="What critics gave it, as Plex has it"
                >
                  Critics
                </.column_header>
                <.column_header
                  sort={@filters.sort}
                  column="audience"
                  params={@filters}
                  title="What audiences gave it, as Plex has it"
                >
                  Audience
                </.column_header>
                <.column_header sort={@filters.sort} column="studio" params={@filters}>
                  Studio
                </.column_header>
                <.column_header sort={@filters.sort} column="status" params={@filters}>
                  Theme
                </.column_header>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={item <- @items}
                class={[
                  "border-b border-border/60 transition-colors hover:bg-muted/40",
                  MapSet.member?(@selected, item.id) && "bg-primary/5"
                ]}
              >
                <td class="px-3 py-2">
                  <input
                    type="checkbox"
                    phx-click="toggle_select"
                    phx-value-id={item.id}
                    checked={MapSet.member?(@selected, item.id)}
                    aria-label={"Select #{item.title}"}
                    class="size-4 rounded border-input"
                  />
                </td>
                <td class="px-1 py-1">
                  <img
                    src={~p"/posters/#{item.id}"}
                    alt=""
                    loading="lazy"
                    class="h-12 w-8 rounded bg-muted object-cover"
                  />
                </td>
                <td class="px-3 py-2">
                  <.link
                    navigate={~p"/library/#{item.id}?#{item_params(@filters)}"}
                    class="font-medium hover:underline"
                  >
                    {item.title}
                  </.link>
                  <span
                    :if={item.manual_theme_url not in [nil, ""]}
                    class="ml-2 rounded-full bg-muted px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-muted-foreground"
                    title="A theme was picked by hand for this item"
                  >
                    picked
                  </span>
                </td>
                <td class="px-3 py-2 text-muted-foreground">{item.year}</td>
                <td class="px-3 py-2 text-muted-foreground">
                  {if item.kind == :show, do: "Series", else: "Movie"}
                </td>
                <.score_cell score={item.critic_score} source={item.critic_score_source} />
                <.score_cell score={item.audience_score} source={item.audience_score_source} />
                <%!-- What Apply would actually use. Without it, a bulk apply
                over a cold cache skips most of the selection for a reason
                nothing on this page mentioned. --%>
                <td
                  class="max-w-40 truncate px-3 py-2 text-muted-foreground"
                  title={studio_title(item)}
                >
                  {item.studio}
                </td>
                <td class="px-3 py-2"><.status_badge status={item.theme_status} /></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          :if={@pages > 1}
          class="flex flex-col items-center gap-2 text-sm text-muted-foreground"
        >
          <nav class="flex flex-wrap items-center justify-center gap-1" aria-label="Pagination">
            <.link
              :if={@page > 1}
              patch={~p"/?#{filter_params(@filters, @page - 1)}"}
              class="rounded-md border border-border px-3 py-1.5 hover:bg-accent hover:text-accent-foreground"
            >
              Previous
            </.link>

            <%= for entry <- page_numbers(@page, @pages) do %>
              <span :if={entry == :gap} class="px-1.5 text-muted-foreground">…</span>
              <.link
                :if={entry != :gap}
                patch={~p"/?#{filter_params(@filters, entry)}"}
                aria-current={entry == @page && "page"}
                class={[
                  "min-w-9 rounded-md border px-2.5 py-1.5 text-center tabular-nums",
                  entry == @page && "border-primary bg-primary font-medium text-primary-foreground",
                  entry != @page && "border-border hover:bg-accent hover:text-accent-foreground"
                ]}
              >
                {entry}
              </.link>
            <% end %>

            <.link
              :if={@page < @pages}
              patch={~p"/?#{filter_params(@filters, @page + 1)}"}
              class="rounded-md border border-border px-3 py-1.5 hover:bg-accent hover:text-accent-foreground"
            >
              Next
            </.link>
          </nav>
          <span>Page {@page} of {@pages}</span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  # First and last are always reachable, with a window around the current page
  # and `:gap` standing in for the stretches left out. A library of a few
  # thousand titles is 60-odd pages, and a button per page would wrap into a
  # wall of numbers that is harder to use than the two arrows it replaced.
  def page_numbers(page, pages) do
    window =
      (page - @window)..(page + @window)
      |> Enum.filter(&(&1 >= 1 and &1 <= pages))

    [1, pages]
    |> Enum.concat(window)
    |> Enum.filter(&(&1 >= 1 and &1 <= pages))
    |> Enum.uniq()
    |> Enum.sort()
    |> insert_gaps()
  end

  # A gap standing in for a single page is wider than the page it hides, so
  # the number goes in instead.
  defp insert_gaps([a, b | rest]) when b - a == 2, do: [a, a + 1 | insert_gaps([b | rest])]
  defp insert_gaps([a, b | rest]) when b - a > 2, do: [a, :gap | insert_gaps([b | rest])]
  defp insert_gaps([a | rest]), do: [a | insert_gaps(rest)]
  defp insert_gaps([]), do: []

  # The studio column is truncated, so the tooltip carries the full name --
  # and the collections, which have nowhere else to show on a row and are
  # exactly what someone squinting at "Walt Disney Pictures" wants to see.
  defp studio_title(%{studio: nil, collections: []}), do: nil
  defp studio_title(%{studio: studio, collections: []}), do: studio

  defp studio_title(item) do
    [item.studio, Enum.join(item.collections, ", ")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" -- ")
  end

  # The page links carry the whole view, sort included. A sorted list is a
  # different list: paging without the sort hands back page 2 of the default
  # title order, which is not the second page of anything the reader was
  # looking at. Same for studio and collection -- page 2 of a filter that has
  # been dropped is a page of items the filter excluded.
  defp filter_params(filters, page) do
    filters
    |> header_params(filters.sort)
    |> put_page(page)
  end

  # Page 1 is the absence of a page, so it stays out of the URL.
  defp put_page(params, 1), do: params
  defp put_page(params, page), do: Map.put(params, "page", page)

  attr :status, :atom, required: true

  # The *arr colour vocabulary: red demands action, green is settled, blue is
  # informational. Failed gets the loudest treatment because it is the only
  # state that asks the operator to do something.
  def status_badge(assigns) do
    {label, classes} =
      case assigns.status do
        :missing ->
          {"Missing", "bg-destructive/15 text-destructive"}

        :failed ->
          {"Failed", "bg-destructive text-destructive-foreground"}

        :plex_supplied ->
          {"Plex", "bg-primary/15 text-primary"}

        :fanfarr_applied ->
          {"Fanfarr", "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"}

        :local_file ->
          {"Local file", "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"}

        _ ->
          {"Unknown", "bg-muted text-muted-foreground"}
      end

    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span class={["inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium", @classes]}>
      {@label}
    </span>
    """
  end

  attr :sort, :string, default: nil
  attr :column, :string, required: true
  attr :params, :map, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true

  defp column_header(assigns) do
    assigns =
      assigns
      |> assign(:next, sort_link(assigns.sort, assigns.column))
      |> assign(:indicator, sort_indicator(assigns.sort, assigns.column))

    ~H"""
    <th class="px-3 py-2 font-medium">
      <.link
        patch={~p"/?#{header_params(@params, @next)}"}
        title={@title}
        class="inline-flex items-center gap-1 hover:text-foreground"
      >
        {render_slot(@inner_block)}
        <.icon :if={@indicator} name={@indicator} class="size-3" />
      </.link>
    </th>
    """
  end

  # Paging is deliberately dropped: a re-sorted list has different things on
  # page 7, so staying there lands somewhere arbitrary rather than where the
  # reader was.
  defp header_params(filters, sort) do
    %{
      "status" => filters.status,
      "kind" => filters.kind,
      "studio" => filters.studio,
      "collection" => filters.collection,
      "q" => filters.q,
      "sort" => sort
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, "", "all"] end)
    |> Map.new()
  end

  # Opening an item carries the view it was opened from, so the item page's
  # own "Library" link can put the reader back where they were rather than at
  # an unfiltered first page. Narrowing a two-thousand-item library to the
  # eleven that failed, opening one, and losing the eleven is the whole
  # problem this solves.
  #
  # The page is included here where the sort links deliberately drop it: a
  # re-sorted list has different things on page 7, but the *same* list does
  # not, so returning to it should land where it was left.
  defp item_params(filters), do: filter_params(filters, filters.page)

  attr :score, :float, default: nil
  attr :source, :string, default: nil

  defp score_cell(assigns) do
    ~H"""
    <td class="px-3 py-2 text-muted-foreground">
      <span
        :if={@score}
        title={"#{Fanfarr.Library.Score.label(@source)} · #{Fanfarr.Library.Score.out_of_ten(@score)}/10 as Plex stores it"}
        class="tabular-nums"
      >
        {Fanfarr.Library.Score.format(@score)}
      </span>
      <%!-- An em dash rather than a zero: no rating is not a bad rating, and
      a column of noughts would read as one. --%>
      <span :if={is_nil(@score)} class="opacity-40">—</span>
    </td>
    """
  end
end
