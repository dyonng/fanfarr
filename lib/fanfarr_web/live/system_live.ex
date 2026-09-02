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

  alias Fanfarr.Diagnostics
  alias Fanfarr.Health.Monitor

  @log_levels ~w(debug info warning error)

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Monitor.latest()

    socket =
      socket
      |> assign(:page_title, "System")
      |> assign(:snapshot, snapshot)
      |> assign(:running, false)
      |> assign(:about, about())
      |> assign(:log_level, "info")
      |> assign(:tool, nil)
      |> assign(:tool_output, nil)
      |> assign(:tool_running, false)
      |> assign(:plex_path, "/library/sections")
      |> assign(:probe_url, "")
      |> assign(:item_query, "")
      |> load_logs()

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

  def handle_event("refresh_logs", _params, socket), do: {:noreply, load_logs(socket)}

  def handle_event("set_log_level", %{"level" => level}, socket) when level in @log_levels do
    {:noreply, socket |> assign(:log_level, level) |> load_logs()}
  end

  def handle_event("clear_logs", _params, socket) do
    Fanfarr.Log.Buffer.clear()
    {:noreply, socket |> load_logs() |> put_flash(:info, "Log buffer cleared")}
  end

  # Every tool runs off the LiveView process: they shell out to yt-dlp, talk to
  # Plex, and touch the filesystem, none of which should be able to hold the
  # page hostage or crash it.
  def handle_event("tool", %{"tool" => tool} = params, socket) do
    socket =
      socket |> assign(:tool, tool) |> assign(:tool_running, true) |> assign(:tool_output, nil)

    socket =
      case tool do
        "environment" ->
          start_async(socket, :tool, fn -> Diagnostics.environment() end)

        "bundle" ->
          start_async(socket, :tool, fn -> Diagnostics.bundle() end)

        "plex" ->
          path = params["path"] || socket.assigns.plex_path
          socket = assign(socket, :plex_path, path)
          start_async(socket, :tool, fn -> Diagnostics.plex_probe(path) end)

        "video" ->
          url = params["url"] || socket.assigns.probe_url
          socket = assign(socket, :probe_url, url)
          start_async(socket, :tool, fn -> Diagnostics.video_probe(url) end)

        "item" ->
          query = String.trim(params["query"] || socket.assigns.item_query)
          socket = assign(socket, :item_query, query)
          start_async(socket, :tool, fn -> item_report(query) end)
      end

    {:noreply, socket}
  end

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

  @impl true
  def handle_async(:tool, {:ok, output}, socket) do
    {:noreply, socket |> assign(:tool_running, false) |> assign(:tool_output, output)}
  end

  def handle_async(:tool, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:tool_running, false)
     |> assign(:tool_output, "The tool crashed: #{inspect(reason, limit: 5)}")}
  end

  # Accepts an id or a title, because nobody has an item's UUID to hand.
  defp item_report(""), do: "Enter part of a title, or an item id."

  defp item_report(query) do
    items = Fanfarr.Library.list_media_items!()

    match =
      Enum.find(items, &(&1.id == query)) ||
        Enum.find(items, &String.contains?(String.downcase(&1.title), String.downcase(query)))

    case match do
      nil -> "No item matches #{inspect(query)}."
      item -> Diagnostics.item_report(item.id)
    end
  end

  defp load_logs(socket) do
    level = String.to_existing_atom(socket.assigns.log_level)
    assign(socket, :logs, Fanfarr.Log.Buffer.entries(level: level, limit: 200))
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

        <section class="rounded-lg border border-border bg-card">
          <div class="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3">
            <div>
              <h2 class="text-sm font-semibold text-card-foreground">Log</h2>
              <p class="text-xs text-muted-foreground">
                The last 400 lines, held in memory. Secrets are removed as they are captured, so
                this is safe to paste into a bug report.
              </p>
            </div>
            <div class="flex items-center gap-2">
              <form phx-change="set_log_level">
                <select
                  name="level"
                  class="h-8 rounded-md border border-input bg-background px-2 text-xs"
                >
                  <option
                    :for={level <- ~w(debug info warning error)}
                    value={level}
                    selected={@log_level == level}
                  >
                    {level} and above
                  </option>
                </select>
              </form>
              <button
                phx-click="refresh_logs"
                class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground"
              >
                <.icon name="lucide-refresh-cw" class="size-3.5" /> Refresh
              </button>
              <.copy_button target="log-output" />
              <button
                phx-click="clear_logs"
                class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground"
              >
                <.icon name="lucide-trash-2" class="size-3.5" /> Clear
              </button>
            </div>
          </div>
          <pre
            id="log-output"
            class="max-h-96 overflow-auto whitespace-pre-wrap break-all px-4 py-3 font-mono text-[11px] leading-relaxed text-muted-foreground"
          >{Diagnostics.log_text(@logs)}</pre>
        </section>

        <section class="rounded-lg border border-border bg-card">
          <div class="border-b border-border px-4 py-3">
            <h2 class="text-sm font-semibold text-card-foreground">Diagnostics</h2>
            <p class="text-xs text-muted-foreground">
              Answers questions about this install that would otherwise need a shell. Output is
              redacted; copy it into a bug report.
            </p>
          </div>

          <div class="space-y-3 p-4">
            <div class="flex flex-wrap gap-2">
              <button
                phx-click="tool"
                phx-value-tool="environment"
                class="h-8 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground"
              >
                Environment
              </button>
              <button
                phx-click="tool"
                phx-value-tool="bundle"
                class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-2.5 text-xs font-medium text-primary-foreground hover:bg-primary/90"
              >
                <.icon name="lucide-clipboard-list" class="size-3.5" /> Everything (for a bug report)
              </button>
            </div>

            <form phx-submit="tool" class="flex flex-wrap gap-2">
              <input type="hidden" name="tool" value="item" />
              <input
                type="text"
                name="query"
                value={@item_query}
                placeholder="Item title or id — why can't this get a theme?"
                class="h-8 min-w-64 flex-1 rounded-md border border-input bg-background px-2.5 text-xs"
              />
              <button class="h-8 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground">
                Trace item
              </button>
            </form>

            <form phx-submit="tool" class="flex flex-wrap gap-2">
              <input type="hidden" name="tool" value="video" />
              <input
                type="text"
                name="url"
                value={@probe_url}
                placeholder="YouTube URL — can yt-dlp actually download it?"
                class="h-8 min-w-64 flex-1 rounded-md border border-input bg-background px-2.5 font-mono text-xs"
              />
              <button class="h-8 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground">
                Check video
              </button>
            </form>

            <form phx-submit="tool" class="flex flex-wrap gap-2">
              <input type="hidden" name="tool" value="plex" />
              <input
                type="text"
                name="path"
                value={@plex_path}
                placeholder="/library/sections"
                class="h-8 min-w-64 flex-1 rounded-md border border-input bg-background px-2.5 font-mono text-xs"
              />
              <button class="h-8 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground">
                Ask Plex
              </button>
            </form>

            <div :if={@tool_running} class="flex items-center gap-2 text-xs text-muted-foreground">
              <.icon name="lucide-loader-circle" class="size-3.5 animate-spin" /> Running…
            </div>

            <div :if={@tool_output} class="rounded-md border border-border bg-muted/40">
              <div class="flex items-center justify-between border-b border-border px-3 py-1.5">
                <span class="text-xs text-muted-foreground">Output</span>
                <.copy_button target="tool-output" />
              </div>
              <pre
                id="tool-output"
                class="max-h-96 overflow-auto whitespace-pre-wrap break-all px-3 py-2 font-mono text-[11px] leading-relaxed"
              >{@tool_output}</pre>
            </div>
          </div>
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

  attr :target, :string, required: true

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-hook=".CopyText"
      id={"copy-#{@target}"}
      data-target={@target}
      class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-2.5 text-xs hover:bg-accent hover:text-accent-foreground"
    >
      <.icon name="lucide-copy" class="size-3.5" />
      <span data-label>Copy</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
      export default {
        mounted() {
          this.el.addEventListener("click", async () => {
            const source = document.getElementById(this.el.dataset.target)
            if (!source) return
            const label = this.el.querySelector("[data-label]")
            try {
              await navigator.clipboard.writeText(source.innerText)
              label.textContent = "Copied"
            } catch (_) {
              // Clipboard access needs a secure context, which a LAN address
              // over plain http is not. Selecting the text is the fallback.
              const range = document.createRange()
              range.selectNodeContents(source)
              const selection = window.getSelection()
              selection.removeAllRanges()
              selection.addRange(range)
              label.textContent = "Selected — press Ctrl+C"
            }
            setTimeout(() => { label.textContent = "Copy" }, 2500)
          })
        }
      }
    </script>
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
