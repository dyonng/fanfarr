defmodule FanfarrWeb.ActivityLive.Index do
  @moduledoc """
  What Fanfarr is doing and what it has done: running and queued Oban jobs,
  and the theme application log. This is where a stuck fetch or a rate-limited
  request becomes visible instead of failing silently -- the page the brief
  calls out by name.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  import Ecto.Query, only: [from: 2]

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

  defp load(socket) do
    jobs =
      Fanfarr.Repo.all(
        from j in Oban.Job,
          order_by: [desc: j.id],
          limit: 30,
          select: [:id, :worker, :state, :queue, :attempt, :max_attempts, :errors, :inserted_at]
      )

    socket
    |> assign(:jobs, jobs)
    |> assign(:failures, Fanfarr.Themes.list_theme_failures!() |> Enum.take(20))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={:activity} current_user={@current_user}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Activity</h1>
          <p class="text-sm text-muted-foreground">Jobs refresh every few seconds.</p>
        </div>

        <section class="rounded-lg border border-border bg-card">
          <h2 class="border-b border-border px-4 py-3 text-sm font-semibold text-card-foreground">
            Queue
          </h2>
          <div :if={@jobs == []} class="px-4 py-6 text-sm text-muted-foreground">
            No jobs yet. A library sync or theme refresh will appear here.
          </div>
          <table :if={@jobs != []} class="w-full text-sm">
            <tbody>
              <tr :for={job <- @jobs} class="border-b border-border/60 last:border-0">
                <td class="px-4 py-2 font-mono text-xs">{short_worker(job.worker)}</td>
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

  defp short_worker(worker), do: worker |> String.split(".") |> List.last()

  defp last_error(%{errors: []}), do: ""

  defp last_error(%{errors: errors}) do
    errors |> List.last() |> Map.get("error", "") |> String.slice(0, 500)
  end
end
