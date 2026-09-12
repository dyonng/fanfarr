defmodule FanfarrWeb.ActivityLive.Index do
  @moduledoc """
  What Fanfarr is doing and what it has done: running and queued Oban jobs,
  and the theme application log. This is where a stuck fetch or a rate-limited
  request becomes visible instead of failing silently -- the page the brief
  calls out by name.
  """
  use FanfarrWeb, :live_view

  alias Fanfarr.Clock

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, socket |> assign(:page, 1) |> assign(:page_title, "Activity")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page =
      case Integer.parse(params["page"] || "1") do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    {:noreply, socket |> assign(:page, page) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    case Fanfarr.Repo.get(Oban.Job, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Job no longer exists")}

      job ->
        Oban.retry_job(job)
        {:noreply, socket |> put_flash(:info, "Job queued for retry") |> load()}
    end
  end

  def handle_event("stop_bulk", _params, socket) do
    count = Fanfarr.Jobs.cancel_bulk_theme_work!()

    {:noreply,
     socket |> put_flash(:info, "Stopped #{count} queued or running theme job(s)") |> load()}
  end

  defp load(socket) do
    history = Fanfarr.Jobs.history(socket.assigns.page)

    socket
    |> assign(:jobs, history.entries)
    |> assign(:page, history.page)
    |> assign(:pages, history.pages)
    |> assign(:total, history.total)
    |> assign(:summary, Fanfarr.Jobs.summary())
    |> assign(:bulk_theme_work_pending, Fanfarr.Jobs.bulk_theme_work_pending?())
    |> assign(:eta, Fanfarr.Jobs.eta_seconds())
  end

  # Nothing at all when there is no estimate, rather than a placeholder: the
  # sentence has to read correctly with this part missing, which is the
  # ordinary case on a fresh install.
  defp remaining(nil), do: ""
  defp remaining(seconds), do: " · #{humanise(seconds)} left"

  # Deliberately coarse. The estimate is an average over recent jobs and the
  # next download can be twice the last one, so "about 40 minutes" is as
  # precise as the underlying number can honestly be written.
  defp humanise(seconds) when seconds < 60, do: "under a minute"

  defp humanise(seconds) when seconds < 5400 do
    case round(seconds / 60) do
      1 -> "about a minute"
      minutes -> "about #{minutes} minutes"
    end
  end

  defp humanise(seconds) do
    hours = seconds / 3600

    if hours < 1.5,
      do: "about an hour",
      else: "about #{round(hours)} hours"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={:activity}
      current_user={@current_user}
      queue={@queue}
    >
      <div class="space-y-6">
        <Layouts.page_header title="Activity">
          <:subtitle>
            <span :if={Fanfarr.Jobs.busy?(@summary)}>
              {@summary.running} running · {@summary.queued} waiting{remaining(@eta)}. Everything
              here runs in the background, so you can leave this page.
            </span>
            <span :if={not Fanfarr.Jobs.busy?(@summary)}>
              Nothing running. Jobs refresh every few seconds.
            </span>
          </:subtitle>
          <:actions>
            <button
              :if={@bulk_theme_work_pending}
              phx-click="stop_bulk"
              class="h-11 whitespace-nowrap rounded-md border border-border px-3 text-sm font-medium hover:bg-accent hover:text-accent-foreground sm:h-9"
            >
              Stop bulk theme work
            </button>
          </:actions>
        </Layouts.page_header>

        <section class="rounded-lg border border-border bg-card">
          <div class="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3">
            <h2 class="text-sm font-semibold text-card-foreground">Queue</h2>
            <p class="text-xs text-muted-foreground">
              <span :if={@total > 0}>
                {@total} {if @total == 1, do: "entry", else: "entries"} · keeping the newest
                <.link navigate={~p"/settings"} class="underline hover:no-underline">
                  {Fanfarr.Jobs.history_limit()} finished
                </.link>
                <%!-- Said once here rather than on a hundred rows. Every time
                on this page is the server's, so stating it per cell would be
                the same word repeated down the column. --%>
                · times in {Fanfarr.Clock.zone()}
              </span>
            </p>
          </div>

          <div :if={@jobs == []} class="px-4 py-6 text-sm text-muted-foreground">
            No jobs yet. A library sync or theme refresh will appear here.
          </div>

          <div :if={@jobs != []} class="overflow-x-auto">
            <%!-- No width floor below sm. Eight columns do not fit a phone,
            and the two that carry the least there -- when it started and how
            long it took, both implied by "Queued" and the state badge -- stand
            down rather than being pushed behind a scroll. What is left still
            scrolls inside this box, which is the deal for tables here; the
            page itself does not move. --%>
            <table class="w-full text-sm sm:min-w-[48rem]">
              <thead>
                <tr class="border-b border-border text-left text-xs font-medium text-muted-foreground">
                  <th scope="col" class="px-4 py-2">Action</th>
                  <th scope="col" class="px-3 py-2">Item</th>
                  <th scope="col" class="px-2 py-2">State</th>
                  <th scope="col" class="px-2 py-2">Queued</th>
                  <th scope="col" class="hidden px-2 py-2 sm:table-cell">Started</th>
                  <th scope="col" class="hidden px-2 py-2 sm:table-cell">Took</th>
                  <th scope="col" class="px-2 py-2">Details</th>
                  <th scope="col" class="px-4 py-2 text-right">
                    <span class="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={job <- @jobs}
                  id={"job-#{job.id}"}
                  class="border-b border-border/60 last:border-0"
                >
                  <%!-- The label only. It used to print the worker module
                  under it as well, so every apply row read "Apply theme"
                  and then "ApplyTheme" -- the same fact twice, once in
                  English and once in Elixir. --%>
                  <td class="px-4 py-2">{job.label}</td>

                  <td class="px-3 py-2">
                    <.link
                      :if={job.item_id && job.item_title}
                      navigate={~p"/library/#{job.item_id}"}
                      class="hover:underline"
                    >
                      {job.item_title}
                    </.link>
                    <span
                      :if={job.item_id && is_nil(job.item_title)}
                      class="text-muted-foreground"
                      title="The item this job was queued for no longer exists"
                    >
                      removed item
                    </span>
                    <span :if={is_nil(job.item_id)} class="text-xs text-muted-foreground">—</span>
                  </td>

                  <td class="px-2 py-2 whitespace-nowrap">
                    <span
                      class={[
                        "rounded-full px-2 py-0.5 text-xs font-medium",
                        job.state == "completed" &&
                          "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
                        job.state == "executing" && "bg-primary/15 text-primary",
                        job.state in ["retryable", "discarded"] &&
                          "bg-destructive/15 text-destructive",
                        job.state in ["available", "scheduled", "cancelled"] &&
                          "bg-muted text-muted-foreground"
                      ]}
                      title={"#{job.queue} queue · attempt #{job.attempt} of #{job.max_attempts}"}
                    >
                      {job.state}
                    </span>
                    <%!-- The attempt count had a column of its own reading
                    "attempt 1/3" on every row, which is the answer nobody is
                    asking. It is only interesting once it is not 1, so that
                    is when it shows. --%>
                    <span :if={job.attempt > 1} class="ml-1 text-xs text-muted-foreground">
                      ×{job.attempt}
                    </span>
                  </td>

                  <td class="px-2 py-2 text-xs whitespace-nowrap text-muted-foreground">
                    <.at at={job.inserted_at} />
                  </td>
                  <td class="hidden px-2 py-2 text-xs whitespace-nowrap text-muted-foreground sm:table-cell">
                    <.at at={job.attempted_at} />
                  </td>
                  <td class="hidden px-2 py-2 text-xs whitespace-nowrap tabular-nums text-muted-foreground sm:table-cell">
                    {took(job)}
                  </td>

                  <td class="px-2 py-2 text-xs text-destructive">
                    <details :if={job.errors != []}>
                      <summary class="cursor-pointer">last error</summary>
                      <pre class="mt-1 max-w-xl overflow-x-auto whitespace-pre-wrap text-xs">{last_error(job)}</pre>
                    </details>
                  </td>

                  <td class="px-4 py-2 text-right">
                    <button
                      :if={job.state in ["retryable", "discarded", "cancelled"]}
                      phx-click="retry"
                      phx-value-id={job.id}
                      class="inline-flex min-h-10 items-center rounded-md border border-border px-2 py-1 text-xs hover:bg-accent hover:text-accent-foreground sm:min-h-0"
                    >
                      Retry
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@pages > 1} class="border-t border-border px-4 py-3">
            <.pager
              page={@page}
              pages={@pages}
              position="below the queue"
              href={fn entry -> ~p"/activity?page=#{entry}" end}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :at, :any, required: true

  # Rendered in the server's zone, with the exact local time on hover. The
  # relative reading is the one being asked for -- "is this recent?" -- and it
  # stays fresh without any JavaScript because the page already repaints every
  # few seconds.
  defp at(%{at: nil} = assigns), do: ~H|<span class="text-muted-foreground">—</span>|

  defp at(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={"#{Clock.precise(@at)} #{Clock.offset(@at)}"}>
      {Clock.ago(@at)}
    </time>
    """
  end

  # How long the job took, or how long it has been going. Oban records the
  # finish in a different column depending on how the job ended, so all three
  # are read; a job that has started and not finished is measured against now,
  # which is what makes a stuck download visible as a number that keeps
  # climbing rather than a badge that never changes.
  defp took(%{attempted_at: nil}), do: "—"

  defp took(%{attempted_at: started} = job) do
    case finished_at(job) do
      nil -> duration(DateTime.diff(DateTime.utc_now(), started)) <> "…"
      done -> duration(DateTime.diff(done, started))
    end
  end

  defp finished_at(job) do
    job.completed_at || job.cancelled_at || job.discarded_at
  end

  defp duration(seconds) when seconds < 0, do: "—"
  defp duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp duration(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp last_error(%{errors: []}), do: ""

  defp last_error(%{errors: errors}) do
    errors |> List.last() |> Map.get("error", "") |> String.slice(0, 500)
  end
end
