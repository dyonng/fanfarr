defmodule FanfarrWeb.LibraryLive.Index do
  @moduledoc """
  The default view: every show and movie, with theme status front and centre.

  Follows the Sonarr table register -- dense rows, status colour semantics,
  filters that narrow rather than navigate. Served entirely from the SQLite
  mirror; Plex is never queried to render this page.
  """
  use FanfarrWeb, :live_view

  require Ash.Query

  alias Fanfarr.Library.MediaItem

  @page_size 50

  # Every column the table can draw, in the order it draws them.
  #
  # A view preference, not part of the schema. The columns marked hidden are
  # the ones that arrived later and are not shown unless asked for: a table is
  # readable at a glance or it is not read, and eleven columns is not. The
  # choice is saved as a setting (`library_columns`) and a `?cols=` parameter
  # overrides it for one view without changing it.
  #
  # Declared here, above everything that reads them, because a module attribute
  # is read where it is written down: below the code that uses it, Elixir warns
  # that it is undefined and the assign is nil.
  @columns [
    %{key: "title", label: "Title"},
    %{key: "year", label: "Year"},
    %{key: "kind", label: "Type (show or movie)"},
    %{key: "critic", label: "Critics"},
    %{key: "audience", label: "Audience"},
    %{key: "studio", label: "Studio"},
    %{key: "status", label: "Theme"},
    %{key: "size", label: "Size"},
    %{key: "length", label: "Length"},
    %{key: "added", label: "Date added to Plex", hidden: true},
    %{key: "seasons", label: "Seasons", hidden: true}
  ]

  @column_keys Enum.map(@columns, & &1.key)
  @default_columns @columns |> Enum.reject(&Map.get(&1, :hidden, false)) |> Enum.map(& &1.key)

  # How many pages to show either side of the current one.

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Fanfarr.PubSub, "library")

    {:ok,
     socket
     |> assign(:selected, MapSet.new())
     |> assign(:show_columns, false)
     |> assign(:columns, @columns)
     |> assign(:visible_columns, @default_columns)
     # Gates the bulk trim, which is the auto-crop feature wearing a different
     # hat: the crop itself is found by the worker, not here.
     |> assign(:crop_enabled, Fanfarr.Themes.AutoCrop.enabled?())
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
      page: max(String.to_integer(params["page"] || "1"), 1),
      # Kept exactly as it arrived. The resolved list is what the table draws,
      # but the URL has to go on carrying what was asked for -- otherwise
      # sorting a `?cols=` view would pin the set as a saved preference.
      columns_param: params["cols"]
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:visible_columns, resolve_columns(filters))
     |> load_items()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    # Only the form's own fields: a phx-change payload also carries _target,
    # which would end up in the URL.
    overrides = Map.take(params, ["status", "kind", "studio", "collection", "q"])

    {:noreply, push_patch(socket, to: ~p"/library?#{query_params(socket, overrides)}")}
  end

  # --- which columns --------------------------------------------------------

  def handle_event("edit_columns", _params, socket) do
    {:noreply, assign(socket, :show_columns, true)}
  end

  def handle_event("close_columns", _params, socket) do
    {:noreply, assign(socket, :show_columns, false)}
  end

  # A form with nothing ticked sends no parameter at all, so "nothing chosen"
  # is an ordinary case rather than an edge one. Title is the floor: a table
  # with no columns is not a view anyone can read, and the modal shows it
  # ticked afterwards rather than silently disagreeing.
  def handle_event("set_columns", params, socket) do
    chosen = params |> Map.get("cols", []) |> List.wrap() |> Enum.filter(&(&1 in @column_keys))
    chosen = if "title" in chosen, do: chosen, else: ["title" | chosen]

    # The table's own order, whatever order the form sent them in.
    chosen = Enum.filter(@column_keys, &(&1 in chosen))

    Fanfarr.Settings.put_setting!("library_columns", Enum.join(chosen, ","))

    # Saved, so the parameter comes out of the URL and the setting takes over.
    {:noreply,
     socket
     |> assign(:show_columns, false)
     |> push_patch(to: ~p"/library?#{query_params(socket, %{"cols" => nil})}")}
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
        "apply" -> {Enum.count(ids, &enqueue_apply/1), "theme writes"}
        "lookup" -> {Enum.count(ids, &enqueue_lookup/1), "ThemerrDB lookups"}
        "trim" -> {Enum.count(ids, &enqueue_trim/1), "theme trims"}
      end

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> put_flash(:info, "Queued #{queued} #{label}")}
  end

  defp enqueue_apply(id), do: match?({:ok, _}, Fanfarr.Workers.ApplyTheme.enqueue(id))

  defp enqueue_lookup(id) do
    match?({:ok, _}, %{media_item_id: id} |> Fanfarr.Workers.LookupTheme.new() |> Oban.insert())
  end

  # The crop is found by the worker rather than here: it needs the audio, and
  # a hundred decodes cannot happen inside a click.
  defp enqueue_trim(id) do
    match?({:ok, _}, %{media_item_id: id} |> Fanfarr.Workers.TrimTheme.new() |> Oban.insert())
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
      |> Ash.Query.load([:theme_status, :theme_size, :theme_duration])
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
      "sort" => filters.sort,
      "cols" => filters.columns_param
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

  @sortable ~w(title year kind critic audience studio status size length added seasons)

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
  # Nil rather than 0 for a title we never wrote a theme for, so it sorts last
  # with the unrated rather than as the smallest size on the page.
  defp key(item, "size"), do: (item.theme_size > 0 && item.theme_size) || nil

  # Already nil when nothing measured it, which is the case the comparator
  # below sorts last.
  defp key(item, "length"), do: item.theme_duration
  defp key(item, "added"), do: item.added_at
  defp key(item, "seasons"), do: item.season_count

  # The order the operator works down: what needs attention first, what is
  # finished last. Alphabetical would put :failed between :fanfarr_applied and
  # :local_file, which is no order at all.
  @status_order [:failed, :missing, :plex_supplied, :local_file, :fanfarr_applied]
  defp status_rank(status), do: Enum.find_index(@status_order, &(&1 == status)) || 99

  # A date is not a number to hand to <=: two DateTimes are maps, and comparing
  # them as terms compares :day before :month and :year, so a library would
  # sort by day of the month. `DateTime.compare/2` is the only order that means
  # anything here.
  defp comparator("added", direction) do
    fn a, b ->
      cond do
        is_nil(a) and is_nil(b) -> true
        is_nil(a) -> false
        is_nil(b) -> true
        direction == :asc -> DateTime.compare(a, b) != :gt
        true -> DateTime.compare(a, b) != :lt
      end
    end
  end

  # A missing score is not a low score, a theme we never wrote is not a
  # zero-byte theme, and a film has no season count rather than none of them.
  # Sorting any of those as if they were zero puts them at the top of an
  # ascending sort, which buries the thing being looked for; they sort last in
  # both directions instead.
  defp comparator(column, direction)
       when column in ~w(critic audience year studio size length seasons) do
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

  # Nothing written by Fanfarr reads as a dash rather than "0 B", which is a
  # claim that a theme file exists and is empty.
  defp theme_size(0), do: "—"
  defp theme_size(size), do: bytes(size)

  # Spelled out on hover, because a dash is only self-explanatory next to the
  # heading, and a row read on its own does not have one.
  defp theme_size_title(0), do: "Fanfarr has not written a theme for this item"
  defp theme_size_title(size), do: "Written by Fanfarr · #{bytes(size)}"

  # Unknown rather than zero: a row with no recorded length is not a theme that
  # plays for no time. Qualified rather than going through the imported helper
  # the rest of this module uses, because this is the one number on a row that
  # must never be mistaken for the size beside it.
  defp theme_length(nil), do: "—"
  defp theme_length(ms), do: FanfarrWeb.Format.duration_ms(ms)

  defp theme_length_title(nil),
    do:
      "No recorded length: either Fanfarr wrote no theme here, or it was applied before the length was logged"

  defp theme_length_title(ms),
    do: "The written theme plays for #{FanfarrWeb.Format.duration_ms(ms)}"

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
        <Layouts.page_header title="Library">
          <:subtitle>
            {@total} items · {Map.get(@counts, :missing, 0)} without a theme
          </:subtitle>
          <:actions>
            <button
              phx-click="edit_columns"
              class="inline-flex h-11 items-center gap-2 whitespace-nowrap rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground sm:h-9"
            >
              <.icon name="lucide-table" class="size-4" /> Columns
            </button>
            <button
              phx-click="sync"
              class="inline-flex h-11 items-center gap-2 whitespace-nowrap rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 sm:h-9"
            >
              <.icon name="lucide-refresh-cw" class="size-4" /> Sync library
            </button>
          </:actions>
        </Layouts.page_header>

        <%!-- Column picker. A plain overlay rather than the vendored dialog:
        the buttons on this page are hand-rolled throughout, and this way the
        whole thing is server-rendered -- nothing to load, and no hook that can
        be missing on a page that otherwise works. --%>
        <div :if={@show_columns} class="fixed inset-0 z-50" role="dialog" aria-modal="true">
          <div class="absolute inset-0 bg-black/50" phx-click="close_columns"></div>

          <div class="relative mx-auto mt-20 w-full max-w-md rounded-lg border border-border bg-card p-4 shadow-lg">
            <h2 class="text-sm font-semibold text-card-foreground">Columns</h2>
            <p class="mt-1 text-xs text-muted-foreground">
              Saved for this library. A <code>?cols=</code>
              in the URL overrides it for one view without changing this.
            </p>

            <form id="library-columns" phx-submit="set_columns" class="mt-3 space-y-2">
              <label :for={column <- @columns} class="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  name="cols[]"
                  value={column.key}
                  checked={column.key in @visible_columns}
                  class="size-4 rounded border-input"
                />
                {column.label}
              </label>

              <div class="mt-4 flex justify-end gap-2">
                <button
                  type="button"
                  phx-click="close_columns"
                  class="inline-flex h-11 items-center rounded-md border border-border px-3 text-sm hover:bg-accent sm:h-9"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="inline-flex h-11 items-center rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 sm:h-9"
                >
                  Save columns
                </button>
              </div>
            </form>
          </div>
        </div>

        <form id="library-filters" phx-change="filter" class="flex flex-wrap items-end gap-2">
          <input
            type="search"
            name="q"
            value={@filters.q}
            placeholder="Search titles…"
            phx-debounce="300"
            class="h-11 w-full rounded-md border border-input bg-background px-3 text-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:h-9 sm:w-56"
          />
          <select
            name="status"
            class="h-11 rounded-md border border-input bg-background px-2 text-sm sm:h-9"
          >
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
          <select
            name="kind"
            class="h-11 rounded-md border border-input bg-background px-2 text-sm sm:h-9"
          >
            <option value="all" selected={@filters.kind in [nil, "", "all"]}>Shows & movies</option>
            <option value="show" selected={@filters.kind == "show"}>Shows</option>
            <option value="movie" selected={@filters.kind == "movie"}>Movies</option>
          </select>
          <select
            :if={@studios != []}
            name="studio"
            class="h-11 max-w-48 rounded-md border border-input bg-background px-2 text-sm sm:h-9"
          >
            <option value="all" selected={@filters.studio in [nil, "", "all"]}>Any studio</option>
            <option :for={studio <- @studios} value={studio} selected={@filters.studio == studio}>
              {studio}
            </option>
          </select>
          <select
            :if={@collections != []}
            name="collection"
            class="h-11 max-w-48 rounded-md border border-input bg-background px-2 text-sm sm:h-9"
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
            phx-value-action="lookup"
            class="inline-flex h-10 items-center gap-1.5 rounded-md border border-border bg-background px-2.5 text-xs hover:bg-accent hover:text-accent-foreground sm:h-8"
          >
            <.icon name="lucide-database" class="size-3.5" /> Look up ThemerrDB
          </button>
          <button
            :if={@crop_enabled}
            phx-click="bulk"
            phx-value-action="trim"
            class="inline-flex h-10 items-center gap-1.5 rounded-md border border-border bg-background px-2.5 text-xs hover:bg-accent hover:text-accent-foreground sm:h-8"
          >
            <.icon name="lucide-scissors" class="size-3.5" /> Trim current themes
          </button>
          <button
            phx-click="bulk"
            phx-value-action="apply"
            class="inline-flex h-10 items-center gap-1.5 rounded-md bg-primary px-2.5 text-xs font-medium text-primary-foreground hover:bg-primary/90 sm:h-8"
          >
            <.icon name="lucide-music" class="size-3.5" /> Apply themes
          </button>
          <button phx-click="clear_selection" class="text-xs text-muted-foreground hover:underline">
            clear
          </button>
        </div>

        <.pagination page={@page} pages={@pages} filters={@filters} position="above the table" />

        <div :if={@items != []} class="overflow-x-auto rounded-lg border border-border">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-border bg-muted/50 text-left text-xs uppercase tracking-wide text-muted-foreground">
                <th class="w-8 p-0">
                  <label class="flex min-h-11 cursor-pointer items-center px-3 py-2 sm:min-h-0">
                    <input
                      type="checkbox"
                      phx-click="select_page"
                      checked={@items != [] and Enum.all?(@items, &MapSet.member?(@selected, &1.id))}
                      aria-label="Select this page"
                      class="size-4 rounded border-input"
                    />
                  </label>
                </th>
                <th class="hidden w-10 px-1 py-2 sm:table-cell"></th>
                <.column_header
                  :if={showing?(@visible_columns, "title")}
                  sort={@filters.sort}
                  column="title"
                  params={@filters}
                >
                  Title
                </.column_header>
                <%!-- On a phone this table is Title and Theme, and that is
                deliberate: "which of these is missing a theme" is what the
                page is for, and the status badge is the answer. The first cut
                left Studio in and pushed Theme off the right-hand edge behind
                a horizontal scroll -- the one column that had to survive was
                the one that did not. The poster goes below sm as well; at 32px
                it is a grey rectangle.

                Nothing becomes unreachable: every hidden column's sort link is
                still a URL, and the item page shows all of it. --%>
                <.column_header
                  :if={showing?(@visible_columns, "year")}
                  sort={@filters.sort}
                  column="year"
                  params={@filters}
                  class="hidden md:table-cell"
                >
                  Year
                </.column_header>
                <.column_header
                  :if={showing?(@visible_columns, "kind")}
                  sort={@filters.sort}
                  column="kind"
                  params={@filters}
                  class="hidden md:table-cell"
                >
                  Type
                </.column_header>
                <.column_header
                  :if={showing?(@visible_columns, "critic")}
                  sort={@filters.sort}
                  column="critic"
                  params={@filters}
                  title="What critics gave it, as Plex has it"
                  class="hidden md:table-cell"
                >
                  Critics
                </.column_header>
                <.column_header
                  :if={showing?(@visible_columns, "audience")}
                  sort={@filters.sort}
                  column="audience"
                  params={@filters}
                  title="What audiences gave it, as Plex has it"
                  class="hidden md:table-cell"
                >
                  Audience
                </.column_header>
                <.column_header
                  :if={showing?(@visible_columns, "studio")}
                  sort={@filters.sort}
                  column="studio"
                  params={@filters}
                  class="hidden md:table-cell"
                >
                  Studio
                </.column_header>
                <.column_header
                  :if={showing?(@visible_columns, "status")}
                  sort={@filters.sort}
                  column="status"
                  params={@filters}
                >
                  Theme
                </.column_header>
                <%!-- What Fanfarr's own write occupies, which is the only part of
                this table an operator can reclaim. Dashes for everything it
                did not write, so the column answers "how much of this did I
                spend" rather than "how big is what Plex has". --%>
                <.column_header
                  :if={showing?(@visible_columns, "size")}
                  sort={@filters.sort}
                  column="size"
                  params={@filters}
                  title="Disk space the theme Fanfarr wrote takes, if it wrote one"
                  class="hidden text-right md:table-cell"
                >
                  Size
                </.column_header>
                <%!-- The length of the file that was written, which is not the
                length of the video it came from: a trimmed theme is shorter.
                It is the second half of "what is this costing me", and the
                half that explains a size that looks large for one track. --%>
                <.column_header
                  :if={showing?(@visible_columns, "length")}
                  sort={@filters.sort}
                  column="length"
                  params={@filters}
                  title="How long the theme Fanfarr wrote plays, if it wrote one"
                  class="hidden text-right md:table-cell"
                >
                  Length
                </.column_header>
                <%!-- Both of these arrive hidden: they are references, not
                the working view, and a table nobody can scan is not a table.
                lg rather than md because they are the two most optional. --%>
                <.column_header
                  :if={showing?(@visible_columns, "added")}
                  sort={@filters.sort}
                  column="added"
                  params={@filters}
                  title="When Plex first saw this title -- Plex's date, not ours"
                  class="hidden lg:table-cell"
                >
                  Added
                </.column_header>
                <.column_header
                  :if={showing?(@visible_columns, "seasons")}
                  sort={@filters.sort}
                  column="seasons"
                  params={@filters}
                  title="How many seasons Plex reports, for a show"
                  class="hidden text-right lg:table-cell"
                >
                  Seasons
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
                <%!-- The box itself stays 16px -- a bigger one looks wrong in
                a dense table -- so the padded label around it is the tap
                target instead. --%>
                <td class="p-0">
                  <label class="flex min-h-11 cursor-pointer items-center px-3 py-2 sm:min-h-0">
                    <input
                      type="checkbox"
                      phx-click="toggle_select"
                      phx-value-id={item.id}
                      checked={MapSet.member?(@selected, item.id)}
                      aria-label={"Select #{item.title}"}
                      class="size-4 rounded border-input"
                    />
                  </label>
                </td>
                <td class="hidden px-1 py-1 sm:table-cell">
                  <img
                    src={~p"/posters/#{item.id}"}
                    alt=""
                    loading="lazy"
                    class="h-12 w-8 rounded bg-muted object-cover"
                  />
                </td>
                <td :if={showing?(@visible_columns, "title")} class="px-3 py-2">
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
                <td
                  :if={showing?(@visible_columns, "year")}
                  class="hidden px-3 py-2 text-muted-foreground md:table-cell"
                >
                  {item.year}
                </td>
                <td
                  :if={showing?(@visible_columns, "kind")}
                  class="hidden px-3 py-2 text-muted-foreground md:table-cell"
                >
                  {if item.kind == :show, do: "Series", else: "Movie"}
                </td>
                <.score_cell
                  :if={showing?(@visible_columns, "critic")}
                  score={item.critic_score}
                  source={item.critic_score_source}
                  class="hidden md:table-cell"
                />
                <.score_cell
                  :if={showing?(@visible_columns, "audience")}
                  score={item.audience_score}
                  source={item.audience_score_source}
                  class="hidden md:table-cell"
                />
                <%!-- What Apply would actually use. Without it, a bulk apply
                over a cold cache skips most of the selection for a reason
                nothing on this page mentioned. --%>
                <td
                  :if={showing?(@visible_columns, "studio")}
                  class="hidden max-w-40 truncate px-3 py-2 text-muted-foreground md:table-cell"
                  title={studio_title(item)}
                >
                  {item.studio}
                </td>
                <td :if={showing?(@visible_columns, "status")} class="px-3 py-2">
                  <.status_badge status={item.theme_status} />
                </td>
                <td
                  :if={showing?(@visible_columns, "size")}
                  class="hidden px-3 py-2 text-right tabular-nums text-muted-foreground md:table-cell"
                  title={theme_size_title(item.theme_size)}
                >
                  {theme_size(item.theme_size)}
                </td>
                <td
                  :if={showing?(@visible_columns, "length")}
                  class="hidden px-3 py-2 text-right tabular-nums text-muted-foreground md:table-cell"
                  title={theme_length_title(item.theme_duration)}
                >
                  {theme_length(item.theme_duration)}
                </td>
                <td
                  :if={showing?(@visible_columns, "added")}
                  class="hidden px-3 py-2 text-muted-foreground lg:table-cell"
                  title="When Plex first saw this title -- Plex's date, not ours"
                >
                  {added_on(item.added_at)}
                </td>
                <td
                  :if={showing?(@visible_columns, "seasons")}
                  class="hidden px-3 py-2 text-right tabular-nums text-muted-foreground lg:table-cell"
                  title="How many seasons Plex reports, for a show"
                >
                  {seasons_shown(item.season_count)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.pagination page={@page} pages={@pages} filters={@filters} position="below the table" />
      </div>
    </Layouts.app>
    """
  end

  attr :page, :integer, required: true
  attr :pages, :integer, required: true
  attr :filters, :map, required: true
  attr :position, :string, required: true

  # Rendered above and below the table both. A library filtered to one status
  # can still be several pages, and having to scroll past fifty rows to reach
  # the control that changes which fifty rows you are looking at is the kind
  # of thing that makes a list feel long.
  defp pagination(assigns) do
    ~H"""
    <.pager
      page={@page}
      pages={@pages}
      position={@position}
      href={fn entry -> ~p"/library?#{filter_params(@filters, entry)}" end}
    />
    """
  end

  @doc false
  # Kept as a delegate because the numbering has its own test file and this is
  # the name it knows. The logic moved to core_components with the markup when
  # the Activity queue needed the same control.
  defdelegate page_numbers(page, pages), to: FanfarrWeb.CoreComponents

  # A gap standing in for a single page is wider than the page it hides, so
  # the number goes in instead.
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

  # --- the column set -------------------------------------------------------

  # The parameter wins when it is there, and the saved setting answers
  # otherwise. Unknown keys are dropped rather than trusted: a hand-edited URL
  # should show fewer columns, not raise.
  defp resolve_columns(%{columns_param: param}) when is_binary(param) do
    case split_columns(param) do
      [] -> saved_columns()
      keys -> keys
    end
  end

  defp resolve_columns(_filters), do: saved_columns()

  defp saved_columns do
    case Fanfarr.Config.get("library_columns") do
      value when is_binary(value) ->
        case split_columns(value) do
          [] -> @default_columns
          keys -> keys
        end

      _ ->
        @default_columns
    end
  end

  defp split_columns(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in @column_keys))
    |> Enum.uniq()
  end

  defp showing?(visible, key), do: key in visible

  # Plex's date, not ours: a title we synced today may have been in the library
  # for years, and dating it by first sight would be a different fact wearing
  # the same name.
  defp added_on(nil), do: "—"
  defp added_on(at), do: Calendar.strftime(Fanfarr.Clock.local(at), "%-d %b %Y")

  defp seasons_shown(nil), do: "—"
  defp seasons_shown(count), do: count

  attr :sort, :string, default: nil
  attr :column, :string, required: true
  attr :params, :map, required: true
  attr :title, :string, default: nil
  # For hiding a column on a narrow screen. The <th> and its <td> have to
  # carry the same classes or the columns stop lining up.
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp column_header(assigns) do
    assigns =
      assigns
      |> assign(:next, sort_link(assigns.sort, assigns.column))
      |> assign(:indicator, sort_indicator(assigns.sort, assigns.column))

    ~H"""
    <th class={["px-3 py-2 font-medium", @class]}>
      <.link
        patch={~p"/library?#{header_params(@params, @next)}"}
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
      "sort" => sort,
      "cols" => filters.columns_param
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
  attr :class, :any, default: nil

  defp score_cell(assigns) do
    ~H"""
    <td class={["px-3 py-2 text-muted-foreground", @class]}>
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
