defmodule FanfarrWeb.ActivityLive.Index do
  @moduledoc """
  What Fanfarr is doing and what it has done: running and queued Oban jobs,
  and the theme application log. This is where a stuck fetch or a rate-limited
  request becomes visible instead of failing silently -- the page the brief
  calls out by name.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, socket |> load() |> assign(:page_title, "Activity")}
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
    socket
    |> assign(:jobs, Fanfarr.Jobs.recent())
    |> assign(:summary, Fanfarr.Jobs.summary())
    |> assign(:bulk_theme_work_pending, Fanfarr.Jobs.bulk_theme_work_pending?())
    |> assign(:eta, Fanfarr.Jobs.eta_seconds())
    |> assign(:failures, Fanfarr.Themes.list_theme_failures!() |> Enum.take(20))
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
        <div class="flex items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Activity</h1>
            <p class="text-sm text-muted-foreground">
              <span :if={Fanfarr.Jobs.busy?(@summary)}>
                {@summary.running} running · {@summary.queued} waiting{remaining(@eta)}. Everything
                here runs in the background, so you can leave this page.
              </span>
              <span :if={not Fanfarr.Jobs.busy?(@summary)}>
                Nothing running. Jobs refresh every few seconds.
              </span>
            </p>
          </div>
          <button
            :if={@bulk_theme_work_pending}
            phx-click="stop_bulk"
            class="h-9 shrink-0 rounded-md border border-border px-3 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          >
            Stop bulk theme work
          </button>
        </div>

        <section class="rounded-lg border border-border bg-card">
          <h2 class="border-b border-border px-4 py-3 text-sm font-semibold text-card-foreground">
            Queue
          </h2>
          <%!-- Running and waiting work sorts first however old it is. Ordered
          purely by id, a job still going gets buried under whatever finished
          while it ran, which is the opposite of what this page is for. --%>
          <div :if={@jobs == []} class="px-4 py-6 text-sm text-muted-foreground">
            No jobs yet. A library sync or theme refresh will appear here.
          </div>
          <table :if={@jobs != []} class="w-full text-sm">
            <tbody>
              <tr :for={job <- @jobs} class="border-b border-border/60 last:border-0">
                <td class="px-4 py-2">
                  <p class="text-sm">{job.label}</p>
                  <p class="font-mono text-xs text-muted-foreground">
                    {Fanfarr.Jobs.short_worker(job.worker)}
                  </p>
                </td>
                <td class="px-3 py-2">
                  <.link
                    :if={job.item_id && job.item_title}
                    navigate={~p"/library/#{job.item_id}"}
                    class="text-sm hover:underline"
                  >
                    {job.item_title}
                  </.link>
                  <span
                    :if={job.item_id && is_nil(job.item_title)}
                    class="text-sm text-muted-foreground"
                    title="The item this job was queued for no longer exists"
                  >
                    removed item
                  </span>
                  <span :if={is_nil(job.item_id)} class="text-xs text-muted-foreground">—</span>
                </td>
                <td class="px-2 py-2">
                  <span class={[
                    "rounded-full px-2 py-0.5 text-xs font-medium",
                    job.state == "completed" &&
                      "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
                    job.state == "executing" && "bg-primary/15 text-primary",
                    job.state in ["retryable", "discarded"] && "bg-destructive/15 text-destructive",
                    job.state in ["available", "scheduled"] && "bg-muted text-muted-foreground",
                    job.state == "cancelled" && "bg-muted text-muted-foreground"
                  ]}>
                    {job.state}
                  </span>
                </td>
                <td class="px-2 py-2 text-xs text-muted-foreground">
                  attempt {job.attempt}/{job.max_attempts} · {job.queue}
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
                    class="rounded-md border border-border px-2 py-1 text-xs hover:bg-accent hover:text-accent-foreground"
                  >
                    Retry
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="rounded-lg border border-border bg-card">
          <h2 class="border-b border-border px-4 py-3 text-sm font-semibold text-card-foreground">
            Recent theme failures
          </h2>
          <div :if={@failures == []} class="px-4 py-6 text-sm text-muted-foreground">
            None. Failures land here with their actual error.
          </div>
          <table :if={@failures != []} class="w-full text-sm">
            <tbody>
              <tr :for={f <- @failures} class="border-b border-border/60 last:border-0">
                <td class="px-4 py-2 text-xs text-muted-foreground whitespace-nowrap">
                  {Calendar.strftime(f.attempted_at, "%Y-%m-%d %H:%M")}
                </td>
                <td class="px-2 py-2">
                  <.link navigate={~p"/library/#{f.media_item_id}"} class="text-sm hover:underline">
                    view item
                  </.link>
                </td>
                <td class="px-2 py-2 text-xs text-destructive">{f.error}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp last_error(%{errors: []}), do: ""

  defp last_error(%{errors: errors}) do
    errors |> List.last() |> Map.get("error", "") |> String.slice(0, 500)
  end
end
