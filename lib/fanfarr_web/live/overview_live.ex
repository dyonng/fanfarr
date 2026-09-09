defmodule FanfarrWeb.OverviewLive.Index do
  @moduledoc """
  The dashboard at `/`: coverage, what needs doing, what is running.

  The library used to be the homepage, which answered "what is in my library"
  on arrival. That is a browsing question, and it is not the one an operator
  opens this with -- they open it to find out whether the thing is keeping up.
  Every number here is a link into the library view that lists exactly those
  titles, so the dashboard is a set of questions and the library is the answer
  to whichever one was clicked.

  Read-only apart from two buttons, both of which only queue work.
  """
  use FanfarrWeb, :live_view

  alias Fanfarr.Overview

  # Long enough not to hammer a homelab box, short enough that a sync started
  # here visibly finishes. The queue widget in the layout polls on its own.
  @refresh 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> load()}
  end

  defp load(socket), do: assign(socket, :overview, Overview.load())

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("sync", _params, socket) do
    case Fanfarr.Workers.SyncLibrary.new(%{}) |> Oban.insert() do
      {:ok, _job} -> {:noreply, socket |> put_flash(:info, "Library sync queued") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not queue the sync")}
    end
  end

  # The whole point of the "needs attention" number: act on all of it without
  # picking through the library. The ids are recomputed at click time rather
  # than carried from the last render -- this page can sit open for hours, and
  # a list assembled before the last sync would apply to titles that have since
  # been themed or deleted.
  def handle_event("apply_ready", _params, socket) do
    ids = Overview.ready_ids()

    queued = Enum.count(ids, &match?({:ok, _}, Fanfarr.Workers.ApplyTheme.enqueue(&1)))

    {:noreply,
     socket
     |> put_flash(:info, "Queued #{queued} theme #{pluralise(queued, "write", "writes")}")
     |> load()}
  end

  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_n, _singular, plural), do: plural

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={:overview}
      current_user={@current_user}
      queue={@queue}
    >
      <div class="space-y-6">
        <Layouts.page_header title="Overview">
          <:subtitle>{summary_line(@overview)}</:subtitle>
          <:actions>
            <button
              phx-click="sync"
              class="inline-flex h-11 items-center gap-2 whitespace-nowrap rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground sm:h-9"
            >
              <.icon name="lucide-refresh-cw" class="size-4" /> Sync library
            </button>
          </:actions>
        </Layouts.page_header>

        <%!-- Nothing configured yet. A dashboard of zeroes tells a new operator
        that something is broken; what they need is the next step. --%>
        <section
          :if={Overview.empty?(@overview)}
          class="rounded-lg border border-dashed border-border p-10 text-center"
        >
          <p class="text-sm font-medium">No titles yet</p>
          <p class="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
            Point Fanfarr at your Plex server under Settings, enable the libraries you want it
            to manage, then run a sync. Everything on this page fills in from there.
          </p>
          <.link
            navigate={~p"/settings"}
            class="mt-4 inline-flex h-11 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 sm:h-9"
          >
            <.icon name="lucide-settings" class="size-4" /> Open Settings
          </.link>
        </section>

        <div :if={!Overview.empty?(@overview)} class="space-y-6">
          <%!-- Coverage first, and per library rather than one grand total:
          "396 of 742" is a number, "TV is behind and the films are done" is
          the shape of the work. --%>
          <section class="rounded-lg border border-border bg-card">
            <div class="border-b border-border px-4 py-3">
              <h2 class="text-sm font-semibold text-card-foreground">Coverage</h2>
            </div>
            <div class="divide-y divide-border/60">
              <%!-- Narrowed as far as the library can express. It filters by
              kind, not by section, so two TV libraries land on the same view
              -- closer than ignoring the row that was clicked, and the
              alternative is a section filter this row does not justify. --%>
              <.link
                :for={section <- @overview.sections}
                navigate={~p"/library?#{section_filter(section)}"}
                class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 hover:bg-muted/40"
              >
                <div class="min-w-0 flex-1 basis-full sm:basis-0">
                  <p class="truncate text-sm font-medium">{section.title}</p>
                  <p class="text-xs text-muted-foreground">
                    {section.themed} of {section.total} · {section.missing} to go
                  </p>
                </div>
                <div class="flex min-w-0 flex-1 items-center gap-3">
                  <div class="h-2 min-w-0 flex-1 overflow-hidden rounded-full bg-muted">
                    <div
                      class={[
                        "h-full rounded-full",
                        section.percent == 100 && "bg-emerald-500",
                        section.percent < 100 && "bg-primary"
                      ]}
                      style={"width: #{section.percent}%"}
                    />
                  </div>
                  <span class="w-10 shrink-0 text-right text-sm tabular-nums">
                    {section.percent}%
                  </span>
                </div>
              </.link>
            </div>
          </section>

          <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
            <%!-- The one panel that asks for something. "130 missing" is not a
            task -- most of those have no source anywhere. "47 ThemerrDB can
            answer" is. --%>
            <section class="rounded-lg border border-border bg-card p-4 lg:col-span-2">
              <h2 class="text-sm font-semibold text-card-foreground">Needs attention</h2>

              <p
                :if={@overview.ready == 0 and @overview.failed == 0 and @overview.plex_supplied == 0}
                class="mt-3 text-sm text-muted-foreground"
              >
                Nothing waiting. Every title ThemerrDB can answer for has been applied.
              </p>

              <dl class="mt-3 space-y-2 text-sm">
                <.attention
                  :if={@overview.ready > 0}
                  count={@overview.ready}
                  label="missing a theme that ThemerrDB has an answer for"
                  to={~p"/library?#{%{"status" => "missing"}}"}
                  tone={:action}
                />
                <.attention
                  :if={@overview.failed > 0}
                  count={@overview.failed}
                  label="failed on the last attempt"
                  to={~p"/library?#{%{"status" => "failed"}}"}
                  tone={:error}
                />
                <.attention
                  :if={@overview.plex_supplied > 0}
                  count={@overview.plex_supplied}
                  label="playing Plex's own stock theme, replaceable"
                  to={~p"/library?#{%{"status" => "plex_supplied"}}"}
                  tone={:info}
                />
              </dl>

              <button
                :if={@overview.ready > 0}
                phx-click="apply_ready"
                class="mt-4 inline-flex h-11 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90 sm:h-9"
              >
                <.icon name="lucide-music" class="size-4" /> Apply all {@overview.ready}
              </button>
            </section>

            <section class="rounded-lg border border-border bg-card p-4">
              <h2 class="text-sm font-semibold text-card-foreground">Right now</h2>
              <dl class="mt-3 space-y-2 text-sm">
                <div class="flex items-baseline justify-between gap-4">
                  <dt class="text-muted-foreground">Running</dt>
                  <dd class="text-right tabular-nums">{@overview.queue.running}</dd>
                </div>
                <div class="flex items-baseline justify-between gap-4">
                  <dt class="text-muted-foreground">Queued</dt>
                  <dd class="text-right tabular-nums">{@overview.queue.queued}</dd>
                </div>
                <%!-- Only with something to estimate from. A made-up number on
                a fresh install is the one an operator would believe. --%>
                <div
                  :if={@overview.eta_seconds}
                  class="flex items-baseline justify-between gap-4"
                >
                  <dt class="text-muted-foreground">Estimated</dt>
                  <dd class="text-right">{eta(@overview.eta_seconds)}</dd>
                </div>
                <div
                  :for={task <- @overview.schedule}
                  class="flex items-baseline justify-between gap-4"
                >
                  <dt class="min-w-0 truncate text-muted-foreground">{task.label}</dt>
                  <dd class="text-right">{next_run(task.next_run_at)}</dd>
                </div>
              </dl>

              <.link
                navigate={~p"/activity"}
                class="mt-4 inline-flex items-center gap-1 text-xs text-primary hover:underline"
              >
                Open Activity <.icon name="lucide-arrow-right" class="size-3" />
              </.link>
            </section>
          </div>

          <%!-- What Plex just picked up. A new season folder or a film that
          finished importing is exactly the thing that quietly has no theme,
          and the badge on each is the whole point of the panel -- the row is
          worth a glance because sometimes one of them is red. --%>
          <section :if={@overview.recent != []} class="rounded-lg border border-border bg-card">
            <div class="flex flex-wrap items-baseline justify-between gap-2 border-b border-border px-4 py-3">
              <h2 class="text-sm font-semibold text-card-foreground">Recently added</h2>
              <.link navigate={~p"/library"} class="text-xs text-primary hover:underline">
                open Library
              </.link>
            </div>
            <ul class="divide-y divide-border/60">
              <li :for={item <- @overview.recent}>
                <.link
                  navigate={~p"/library/#{item.id}"}
                  class="flex items-center gap-3 px-4 py-2 hover:bg-muted/40"
                >
                  <img
                    src={~p"/posters/#{item.id}"}
                    alt=""
                    loading="lazy"
                    class="h-12 w-8 shrink-0 rounded bg-muted object-cover"
                  />
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-sm font-medium">
                      {item.title}
                      <span :if={item.year} class="font-normal text-muted-foreground">
                        ({item.year})
                      </span>
                    </p>
                    <p class="text-xs text-muted-foreground">{added(item.added_at)}</p>
                  </div>
                  <.status_badge status={item.theme_status} />
                </.link>
              </li>
            </ul>
          </section>

          <%!-- Only what is wrong, and only when something is. System shows
          all eight checks; a green wall here would bury the red one. --%>
          <section
            :if={@overview.health.problems != []}
            class="rounded-lg border border-border bg-card p-4"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h2 class="text-sm font-semibold text-card-foreground">Health</h2>
              <.link navigate={~p"/system"} class="text-xs text-primary hover:underline">
                open System
              </.link>
            </div>
            <ul class="mt-3 space-y-2 text-sm">
              <li
                :for={problem <- @overview.health.problems}
                class="flex items-start gap-2"
              >
                <.icon
                  name={
                    if problem.level == :error,
                      do: "lucide-circle-x",
                      else: "lucide-triangle-alert"
                  }
                  class={[
                    "mt-0.5 size-4 shrink-0",
                    problem.level == :error && "text-destructive",
                    problem.level == :warning && "text-amber-500"
                  ]}
                />
                <%!-- Same fields the System page renders, so the two cannot
                describe the same check differently. --%>
                <div class="min-w-0">
                  <p class="font-medium">{problem.name}</p>
                  <p class="text-xs text-muted-foreground">{problem.message}</p>
                  <p :if={problem.detail} class="text-xs text-muted-foreground">{problem.detail}</p>
                </div>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :to, :string, required: true
  attr :tone, :atom, required: true

  defp attention(assigns) do
    ~H"""
    <.link navigate={@to} class="flex items-baseline gap-3 rounded-md hover:underline">
      <span class={[
        "w-12 shrink-0 text-right text-lg font-semibold tabular-nums",
        @tone == :error && "text-destructive",
        @tone == :action && "text-foreground",
        @tone == :info && "text-muted-foreground"
      ]}>
        {@count}
      </span>
      <span class="min-w-0 text-sm text-muted-foreground">{@label}</span>
    </.link>
    """
  end

  defp section_filter(%{kind: kind}) when kind in [:show, :movie],
    do: %{"status" => "missing", "kind" => to_string(kind)}

  defp section_filter(_section), do: %{"status" => "missing"}

  defp summary_line(%{totals: %{total: 0}}), do: "Nothing synced from Plex yet."

  defp summary_line(%{totals: totals}) do
    "#{totals.themed} of #{totals.total} titles have a theme · #{totals.percent}%"
  end

  # Rounded to a unit the number deserves. "in 4 minutes" from a sample of
  # three jobs is a guess dressed as a measurement.
  defp eta(seconds) when seconds < 60, do: "under a minute"
  defp eta(seconds) when seconds < 3600, do: "about #{round(seconds / 60)} min"
  defp eta(seconds), do: "about #{Float.round(seconds / 3600, 1)} h"

  defp added(nil), do: "date unknown"

  defp added(at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 3600 -> "added just now"
      seconds when seconds < 86_400 -> "added #{round(seconds / 3600)}h ago"
      seconds when seconds < 2_592_000 -> "added #{round(seconds / 86_400)}d ago"
      seconds -> "added #{round(seconds / 2_592_000)}mo ago"
    end
  end

  defp next_run(nil), do: "—"

  defp next_run(at) do
    case DateTime.diff(at, DateTime.utc_now(), :second) do
      seconds when seconds <= 0 -> "due"
      seconds when seconds < 60 -> "in under a minute"
      seconds when seconds < 3600 -> "in #{round(seconds / 60)} min"
      seconds -> "in #{round(seconds / 3600)} h"
    end
  end
end
