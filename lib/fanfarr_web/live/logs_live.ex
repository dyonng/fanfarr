defmodule FanfarrWeb.LogsLive.Index do
  @moduledoc """
  The in-memory application log, filterable and safe to paste into a bug
  report.

  Split out from the System page: health checks and diagnostics are answers
  to specific questions, but the log is something people leave open and
  watch while they try a thing, and it does not belong buried under a
  section that also runs slow probes on demand.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  @log_levels ~w(debug info warning error)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Logs")
     |> assign(:log_level, "info")
     |> assign(:hide_noise, true)
     |> load_logs()}
  end

  @impl true
  def handle_event("refresh_logs", _params, socket), do: {:noreply, load_logs(socket)}

  def handle_event("set_log_level", %{"level" => level}, socket) when level in @log_levels do
    {:noreply, socket |> assign(:log_level, level) |> load_logs()}
  end

  def handle_event("toggle_noise", _params, socket) do
    {:noreply, socket |> assign(:hide_noise, not socket.assigns.hide_noise) |> load_logs()}
  end

  def handle_event("clear_logs", _params, socket) do
    Fanfarr.Log.Buffer.clear()
    {:noreply, socket |> load_logs() |> put_flash(:info, "Log buffer cleared")}
  end

  # Fixed-width columns so timestamps and levels line up down the page and the
  # eye can skip to the message. Padded here rather than with CSS because the
  # whole entry has to be one string.
  defp log_line(entry) do
    level = entry.level |> to_string() |> String.slice(0, 5) |> String.pad_trailing(5)

    "#{Calendar.strftime(entry.at, "%H:%M:%S")}  #{level}  #{entry.message}"
  end

  defp load_logs(socket) do
    level = String.to_existing_atom(socket.assigns.log_level)
    entries = Fanfarr.Log.Buffer.entries(level: level, limit: 400)

    kept =
      if socket.assigns.hide_noise,
        do: Enum.reject(entries, &Fanfarr.Diagnostics.routine_web?(&1.message)),
        else: entries

    socket
    |> assign(:logs, Enum.take(kept, 200))
    |> assign(:hidden_count, length(entries) - length(kept))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={:logs}
      current_user={@current_user}
      queue_summary={@queue_summary}
    >
      <div class="max-w-3xl space-y-6">
        <h1 class="text-2xl font-semibold tracking-tight">Logs</h1>

        <section class="rounded-lg border border-border bg-card">
          <div class="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3">
            <div>
              <h2 class="text-sm font-semibold text-card-foreground">Log</h2>
              <p class="text-xs text-muted-foreground">
                The last 400 lines, held in memory. Secrets are removed as they are captured, so
                this is safe to paste into a bug report.
                <span :if={@hide_noise and @hidden_count > 0}>
                  {@hidden_count} routine web requests hidden.
                </span>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <form id="log-level-form" phx-change="set_log_level">
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
                phx-click="toggle_noise"
                class={[
                  "inline-flex h-8 items-center gap-1.5 rounded-md border px-2.5 text-xs",
                  @hide_noise && "border-primary bg-primary/10 text-primary",
                  !@hide_noise && "border-border hover:bg-accent hover:text-accent-foreground"
                ]}
                title="Hide poster and asset requests, and successful responses"
              >
                <.icon name="lucide-funnel" class="size-3.5" />
                {if @hide_noise, do: "Noise hidden", else: "Showing everything"}
              </button>
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
          <%!-- Rows rather than one block of text: a level cannot be coloured
          inside a <pre>, and innerText still copies as lines, so the copy
          button keeps working. Newest last, so it reads downwards like a log
          and tailing means the bottom. --%>
          <div
            id="log-output"
            phx-hook=".TailLog"
            class="max-h-[32rem] overflow-auto px-4 py-3 font-mono text-[11px] leading-relaxed"
          >
            <p :if={@logs == []} class="text-muted-foreground">(nothing captured yet)</p>
            <%!-- One <pre> per entry, holding a single interpolation.
            whitespace-pre-wrap is needed so a stack trace keeps its shape, but
            it preserves the template's own newlines and indentation just as
            faithfully: spans on separate lines turned every entry into four
            lines with blank ones between. Building the whole line in Elixir
            removes that, and <pre> is what stops the formatter putting the
            interpolation back on its own line. --%>
            <pre
              :for={entry <- Enum.reverse(@logs)}
              class={[
                "m-0 whitespace-pre-wrap break-all font-mono",
                entry.level in [:error, :critical, :alert, :emergency] && "text-destructive",
                entry.level == :warning && "text-amber-600 dark:text-amber-400",
                entry.level == :info && "text-foreground/80",
                entry.level in [:debug, :notice] && "text-muted-foreground/70"
              ]}
            >{log_line(entry)}</pre>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".TailLog">
            export default {
              mounted() {
                // Follow the tail, but stop the moment the reader scrolls up:
                // yanking someone back to the bottom while they are reading an
                // error is worse than not following at all. Coming back to the
                // bottom re-arms it.
                this.follow = true

                this.el.addEventListener("scroll", () => {
                  const distance =
                    this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
                  this.follow = distance < 24
                })

                this.toBottom = () => {
                  if (this.follow) { this.el.scrollTop = this.el.scrollHeight }
                }

                this.toBottom()
              },

              updated() { this.toBottom() }
            }
          </script>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
