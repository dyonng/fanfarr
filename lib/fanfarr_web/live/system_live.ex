defmodule FanfarrWeb.SystemLive.Index do
  @moduledoc """
  Sonarr's System > Status, for this stack: the health checks and the facts
  about this install that a bug report needs.

  Checks are run by `Fanfarr.Health.Monitor` on a schedule; this page shows
  the last snapshot and can force a fresh one. The run happens off the
  LiveView process, since it probes Plex and ThemerrDB with real timeouts.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  alias Fanfarr.Health.Monitor

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Monitor.latest()

    socket =
      socket
      |> assign(:page_title, "System")
      |> assign(:snapshot, snapshot)
      |> assign(:running, false)
      |> assign(:about, about())

    # Nothing yet (fresh boot) -- take the first snapshot now rather than
    # showing an empty page for up to fifteen seconds.
    socket =
      if connected?(socket) and is_nil(snapshot),
        do: run_checks(socket),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, run_checks(socket)}

  @impl true
  def handle_async(:checks, {:ok, snapshot}, socket) do
    {:noreply, socket |> assign(:running, false) |> assign(:snapshot, snapshot)}
  end

  def handle_async(:checks, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:running, false)
     |> put_flash(:error, "Health checks crashed: #{inspect(reason, limit: 5)}")}
  end

  defp run_checks(socket) do
    socket
    |> assign(:running, true)
    |> start_async(:checks, fn -> Monitor.refresh() end)
  end

  defp about do
    %{
      version: Fanfarr.Version.display(),
      database: Fanfarr.Repo.config()[:database],
      cache_dir: Fanfarr.Posters.dir() |> Path.dirname(),
      auth:
        if(Fanfarr.Accounts.AuthMode.required?(),
          do: "login required",
          else: "open (no account configured)"
        ),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      elixir: System.version()
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={:system} current_user={@current_user}>
      <div class="max-w-3xl space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">System</h1>
            <p class="text-sm text-muted-foreground">
              <span :if={@snapshot}>
                Checked {Calendar.strftime(@snapshot.at, "%Y-%m-%d %H:%M:%S UTC")} · re-checked every 10 minutes
              </span>
              <span :if={!@snapshot}>Running the first checks…</span>
            </p>
          </div>
          <button
            phx-click="refresh"
            disabled={@running}
            class="inline-flex h-9 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground disabled:opacity-60"
          >
            <.icon
              name="lucide-refresh-cw"
              class={["size-4", @running && "animate-spin"]}
            /> {if @running, do: "Checking…", else: "Run checks now"}
          </button>
        </div>

        <section class="rounded-lg border border-border bg-card">
          <h2 class="border-b border-border px-4 py-3 text-sm font-semibold text-card-foreground">
            Health
          </h2>
          <div :if={!@snapshot} class="px-4 py-6 text-sm text-muted-foreground">
            No results yet.
          </div>
          <ul :if={@snapshot} class="divide-y divide-border/60">
            <li :for={check <- @snapshot.results} class="flex gap-3 px-4 py-3">
              <.level_dot level={check.level} />
              <div class="min-w-0 flex-1">
                <div class="flex items-baseline justify-between gap-4">
                  <p class="text-sm font-medium">{check.name}</p>
                  <p class={[
                    "text-sm",
                    check.level == :ok && "text-emerald-600 dark:text-emerald-400",
                    check.level == :warning && "text-amber-600 dark:text-amber-400",
                    check.level == :error && "text-destructive"
                  ]}>
                    {check.message}
                  </p>
                </div>
                <p :if={check.detail} class="mt-0.5 text-xs text-muted-foreground">{check.detail}</p>
              </div>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-border bg-card p-4">
          <h2 class="text-sm font-semibold text-card-foreground">About</h2>
          <p class="mt-1 text-xs text-muted-foreground">
            Quote the version line when reporting a problem; it identifies the exact image.
          </p>
          <dl class="mt-3 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[auto_1fr]">
            <dt class="text-muted-foreground">Version</dt>
            <dd class="font-mono text-xs">{@about.version}</dd>
            <dt class="text-muted-foreground">Authentication</dt>
            <dd>{@about.auth}</dd>
            <dt class="text-muted-foreground">Database</dt>
            <dd class="truncate font-mono text-xs">{@about.database}</dd>
            <dt class="text-muted-foreground">Cache</dt>
            <dd class="truncate font-mono text-xs">{@about.cache_dir}</dd>
            <dt class="text-muted-foreground">Runtime</dt>
            <dd class="font-mono text-xs">Elixir {@about.elixir} · OTP {@about.otp}</dd>
          </dl>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :level, :atom, required: true

  defp level_dot(assigns) do
    ~H"""
    <span
      class={[
        "mt-1.5 size-2.5 shrink-0 rounded-full",
        @level == :ok && "bg-emerald-500",
        @level == :warning && "bg-amber-500",
        @level == :error && "bg-destructive"
      ]}
      aria-label={to_string(@level)}
    />
    """
  end
end
