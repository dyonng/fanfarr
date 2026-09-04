defmodule FanfarrWeb.LogsLive.Index do
  @moduledoc """
  The in-memory application log, as a console rather than a card.

  Split out of the System page because it is the one thing there people leave
  open and watch while they try something, rather than a question they ask
  once. That framing decides the layout: it fills the window and the log fills
  what is left after the controls, so the amount you can see is however big
  you made the browser, not a fixed height a card grew past.

  ## Filtering happens here, not in the buffer

  `Fanfarr.Log.Buffer` is asked for everything it holds and the level, noise
  and text filters are applied in this process. Four hundred entries is
  nothing to filter, and it means the level counts in the status bar describe
  the whole buffer rather than only the slice that survived the current
  filter -- which is what makes them useful for deciding what to filter *to*.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  @log_levels ~w(debug info warning error)

  # Frequent enough to read as live while watching a job run, and cheap: a
  # GenServer call for a few hundred entries already in memory.
  @tail_ms 1_000

  # The buffer holds 400; rendering all of them is fine and means a search
  # reaches everything captured rather than a window over it.
  @buffer_limit 400

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Logs")
      |> assign(:log_levels, @log_levels)
      |> assign(:buffer_limit, @buffer_limit)
      |> assign(:log_level, "info")
      |> assign(:hide_noise, true)
      |> assign(:query, "")
      |> assign(:show_source, false)
      |> assign(:wrap, true)
      |> assign(:live, true)
      |> load_logs()

    if connected?(socket) and socket.assigns.live, do: schedule_tail()

    {:ok, socket}
  end

  @impl true
  def handle_info(:tail, socket) do
    if socket.assigns.live do
      schedule_tail()
      {:noreply, load_logs(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_logs", _params, socket), do: {:noreply, load_logs(socket)}

  def handle_event("set_log_level", %{"level" => level}, socket) when level in @log_levels do
    {:noreply, socket |> assign(:log_level, level) |> load_logs()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> load_logs()}
  end

  def handle_event("toggle_noise", _params, socket) do
    {:noreply, socket |> assign(:hide_noise, not socket.assigns.hide_noise) |> load_logs()}
  end

  def handle_event("toggle_source", _params, socket) do
    {:noreply, assign(socket, :show_source, not socket.assigns.show_source)}
  end

  def handle_event("toggle_wrap", _params, socket) do
    {:noreply, assign(socket, :wrap, not socket.assigns.wrap)}
  end

  # Re-arming has to happen here as well as on mount: the timer stops when
  # live goes off, and nothing else would start it again.
  def handle_event("toggle_live", _params, socket) do
    live? = not socket.assigns.live
    if live?, do: schedule_tail()

    {:noreply, socket |> assign(:live, live?) |> load_logs()}
  end

  def handle_event("clear_logs", _params, socket) do
    Fanfarr.Log.Buffer.clear()
    {:noreply, socket |> load_logs() |> put_flash(:info, "Log buffer cleared")}
  end

  defp schedule_tail, do: Process.send_after(self(), :tail, @tail_ms)

  defp load_logs(socket) do
    %{log_level: level, hide_noise: hide_noise, query: query} = socket.assigns

    all = Fanfarr.Log.Buffer.entries(limit: @buffer_limit)

    kept =
      all
      |> Enum.filter(&at_least?(&1.level, String.to_existing_atom(level)))
      |> then(fn entries ->
        if hide_noise,
          do: Enum.reject(entries, &Fanfarr.Diagnostics.routine_web?(&1.message)),
          else: entries
      end)
      |> then(fn entries ->
        case String.trim(query) do
          "" -> entries
          needle -> Enum.filter(entries, &matches?(&1, needle))
        end
      end)

    socket
    |> assign(:logs, kept)
    |> assign(:total, length(all))
    |> assign(:counts, counts(all))
  end

  # Message and source both, so searching for a module name finds what it
  # logged even when the module is not named in the line itself.
  defp matches?(entry, needle) do
    needle = String.downcase(needle)

    String.contains?(String.downcase(entry.message), needle) or
      (entry.where && String.contains?(String.downcase(entry.where), needle))
  end

  defp counts(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      Map.update(acc, bucket(entry.level), 1, &(&1 + 1))
    end)
  end

  # The severities above :error are rare and mean the same thing to someone
  # reading a console, so they count as errors rather than as their own
  # columns nobody would recognise.
  defp bucket(level) when level in [:error, :critical, :alert, :emergency], do: :error
  defp bucket(:warning), do: :warning
  defp bucket(:info), do: :info
  defp bucket(_), do: :debug

  @order ~w(debug info notice warning error critical alert emergency)a
  defp at_least?(level, minimum) do
    Enum.find_index(@order, &(&1 == level)) >= Enum.find_index(@order, &(&1 == minimum))
  end

  # --- rendering a line -------------------------------------------------------
  #
  # Fixed-width columns so timestamps and levels line up down the page and the
  # eye can skip to the message.
  #
  # The markup is built here rather than in the template, and this is the one
  # thing about this file not to undo. The element preserves whitespace so a
  # stack trace keeps its shape, which means a `<span>` per piece written in
  # HEEx puts the template's own newlines and indentation *inside* the line --
  # that turned every entry into four lines with blanks between, once. Emitting
  # exact iodata from one interpolation is what avoids it, and it is also what
  # keeps innerText copying as clean lines for the Copy button.
  #
  # Everything interpolated is escaped here; only the tags and class names are
  # raw, and those are literals in this module.

  @colours %{
    time: "text-muted-foreground/50",
    source: "text-muted-foreground/60",
    # Where something is: a path written, a URL fetched. One colour, because
    # the question they answer is the same one.
    location: "text-sky-600 dark:text-sky-400",
    # Error reasons arrive as atoms -- :econnrefused, :timeout, :enoent -- so
    # this is the colour that most often carries the answer.
    atom: "text-violet-600 dark:text-violet-400",
    string: "text-emerald-600 dark:text-emerald-400",
    number: "text-cyan-600 dark:text-cyan-400",
    module: "text-blue-600 dark:text-blue-400",
    # Our own lines against the framework's.
    tag: "text-primary"
  }

  @level_colours %{
    error: "text-destructive font-semibold",
    warning: "text-amber-600 dark:text-amber-400 font-semibold",
    info: "text-foreground/70",
    debug: "text-muted-foreground/50"
  }

  @doc false
  # Public only so the suite can pin the exact spacing. It cannot be checked
  # through the rendered page: LiveViewTest returns HTML that has been through
  # Floki, which drops the whitespace-only nodes between the column spans, so
  # a page-level test would show columns running together that are correctly
  # separated in a browser.
  def log_line(entry, show_source?) do
    level = entry.level |> to_string() |> String.slice(0, 5) |> String.pad_trailing(5)

    prefix =
      [
        {:time, Calendar.strftime(entry.at, "%H:%M:%S")},
        {nil, "  "},
        {{:level, bucket(entry.level)}, level}
      ] ++
        if show_source? do
          [{nil, "  "}, {:source, String.pad_trailing(entry.where || "-", 34)}]
        else
          []
        end

    (prefix ++ [{nil, "  "}] ++ segments(entry.message))
    |> Enum.map(&span/1)
    |> Phoenix.HTML.raw()
  end

  defp span({nil, text}), do: escape(text)

  defp span({{:level, level}, text}) do
    ["<span class=\"", Map.fetch!(@level_colours, level), "\">", escape(text), "</span>"]
  end

  defp span({kind, text}) do
    ["<span class=\"", Map.fetch!(@colours, kind), "\">", escape(text), "</span>"]
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # One pass to find the interesting runs, then each run is identified by
  # re-testing it.
  #
  # `Regex.split/3` with `include_captures` hands back the matches *and* the
  # plain text between them, indistinguishably, so every classifier below is
  # anchored with \A..\z and has to match a piece whole. Testing only the
  # first character instead coloured "GET /logs" as a module because it
  # happened to start with a capital, and ": " as an atom because it started
  # with a colon.
  #
  # Paths deliberately do not admit spaces. Media directories are full of
  # them, so `/tv/One Piece (1999)/theme.mp3` only highlights as far as the
  # space -- but allowing them made the run swallow the rest of the sentence,
  # and half a path in the right colour beats a paragraph in it.
  @path_body "/[\\w.+\\-]+(?:/[\\w.+\\-]+)+"
  @number_body "\\d+(?:\\.\\d+)?(?:ms|s|µs|%|B|KB|MB)?"
  @module_body "[A-Z][A-Za-z0-9_]*(?:\\.[A-Z][A-Za-z0-9_]*)+"

  @token Regex.compile!(
           Enum.join(
             [
               "https?://[^\\s\"'<>\\]]+",
               "(?<![\\w/])" <> @path_body,
               "\"(?:[^\"\\\\]|\\\\.)*\"",
               "(?<![\\w:]):[a-z_][a-zA-Z0-9_?!]*",
               "\\[[a-z_][a-z_0-9]*\\]",
               "\\b" <> @module_body <> "\\b",
               "\\b" <> @number_body <> "\\b"
             ],
             "|"
           )
         )

  @url ~r{\Ahttps?://\S+\z}
  @path Regex.compile!("\\A" <> @path_body <> "\\z")
  @string ~r/\A"(?:[^"\\]|\\.)*"\z/
  @atom ~r/\A:[a-z_][a-zA-Z0-9_?!]*\z/
  @tag ~r/\A\[[a-z_][a-z_0-9]*\]\z/
  @module Regex.compile!("\\A" <> @module_body <> "\\z")
  @number Regex.compile!("\\A" <> @number_body <> "\\z")

  defp segments(message) do
    @token
    |> Regex.split(message, include_captures: true, trim: true)
    |> Enum.map(&{kind(&1), &1})
  end

  defp kind(piece) do
    cond do
      Regex.match?(@url, piece) -> :location
      Regex.match?(@path, piece) -> :location
      Regex.match?(@string, piece) -> :string
      Regex.match?(@atom, piece) -> :atom
      Regex.match?(@tag, piece) -> :tag
      Regex.match?(@module, piece) -> :module
      Regex.match?(@number, piece) -> :number
      true -> nil
    end
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
      <%!-- The window's height minus the main element's own padding. A console
      is one of the few things that should take the whole screen: the useful
      amount of scrollback is however much the reader made room for. --%>
      <div class="flex h-[calc(100vh-3rem)] flex-col gap-3">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Logs</h1>
            <p class="text-xs text-muted-foreground">
              The last {@buffer_limit} lines, held in memory. Secrets are removed as they are
              captured, so this is safe to paste into a bug report.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle_live"
              class={[
                "inline-flex h-8 items-center gap-1.5 rounded-md border px-2.5 text-xs",
                @live && "border-emerald-500/40 bg-emerald-500/10 text-emerald-600",
                @live && "dark:text-emerald-400",
                !@live && "border-border hover:bg-accent hover:text-accent-foreground"
              ]}
              title="Follow the log as it is written"
            >
              <span class={[
                "size-1.5 rounded-full",
                @live && "animate-pulse bg-emerald-500",
                !@live && "bg-muted-foreground"
              ]} />
              {if @live, do: "Live", else: "Paused"}
            </button>
            <button
              :if={not @live}
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

        <div class="flex flex-wrap items-center gap-2 rounded-lg border border-border bg-card px-3 py-2">
          <form id="log-search-form" phx-change="search" class="relative min-w-56 flex-1">
            <.icon
              name="lucide-search"
              class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground"
            />
            <input
              type="text"
              name="query"
              value={@query}
              placeholder="Filter by text, or by the module that logged it"
              phx-debounce="200"
              autocomplete="off"
              class="h-8 w-full rounded-md border border-input bg-background pl-8 pr-2 text-xs"
            />
          </form>

          <form id="log-level-form" phx-change="set_log_level">
            <select
              name="level"
              class="h-8 rounded-md border border-input bg-background px-2 text-xs"
            >
              <option :for={level <- @log_levels} value={level} selected={@log_level == level}>
                {level} and above
              </option>
            </select>
          </form>

          <.toggle
            click="toggle_noise"
            on={@hide_noise}
            icon="lucide-funnel"
            title="Hide poster and asset requests, and successful responses"
          >
            {if @hide_noise, do: "Noise hidden", else: "All requests"}
          </.toggle>

          <.toggle
            click="toggle_source"
            on={@show_source}
            icon="lucide-file-code"
            title="Show the module and function that logged each line"
          >
            Source
          </.toggle>

          <.toggle
            click="toggle_wrap"
            on={@wrap}
            icon="lucide-wrap-text"
            title="Wrap long lines instead of scrolling sideways"
          >
            Wrap
          </.toggle>
        </div>

        <%!-- min-h-0 is what lets this shrink inside the flex column and
        scroll; without it a long log pushes the container past the viewport
        and the whole page scrolls instead of the console. --%>
        <div class="flex min-h-0 flex-1 flex-col rounded-lg border border-border bg-card">
          <div
            id="log-output"
            phx-hook=".TailLog"
            data-follow={to_string(@live)}
            class={[
              "flex-1 overflow-auto px-4 py-3 font-mono text-[11px] leading-relaxed",
              !@wrap && "whitespace-nowrap"
            ]}
          >
            <p :if={@logs == []} class="text-muted-foreground">
              {if @total == 0,
                do: "(nothing captured yet)",
                else: "Nothing matches. #{@total} lines are hidden by the filters."}
            </p>
            <%!-- The level's colour now sits on the level column rather than
            on the whole line, so the message can be highlighted without the
            red draining out of it. Errors and warnings keep a tint of it
            across the row, which is what makes them findable while scrolling
            rather than something you have to read to notice. --%>
            <pre
              :for={entry <- Enum.reverse(@logs)}
              class={[
                "m-0 font-mono",
                @wrap && "whitespace-pre-wrap break-all",
                !@wrap && "whitespace-pre",
                entry.level in [:error, :critical, :alert, :emergency] && "bg-destructive/10",
                entry.level == :warning && "bg-amber-500/10"
              ]}
            >{log_line(entry, @show_source)}</pre>
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-border px-4 py-1.5 text-[11px] text-muted-foreground">
            <span>{length(@logs)} of {@total} shown</span>
            <span class="flex items-center gap-3">
              <span :if={@counts[:error]} class="text-destructive">
                {@counts[:error]} error{if @counts[:error] > 1, do: "s"}
              </span>
              <span :if={@counts[:warning]} class="text-amber-600 dark:text-amber-400">
                {@counts[:warning]} warning{if @counts[:warning] > 1, do: "s"}
              </span>
              <span :if={@counts[:info]}>{@counts[:info]} info</span>
              <span :if={@counts[:debug]}>{@counts[:debug]} debug</span>
            </span>
            <span :if={@live} class="ml-auto">Following</span>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".TailLog">
            export default {
              mounted() {
                // Follow the tail, but stop the moment the reader scrolls up:
                // yanking someone back to the bottom while they are reading an
                // error is worse than not following at all. Coming back to the
                // bottom re-arms it.
                this.atBottom = true

                this.el.addEventListener("scroll", () => {
                  const distance =
                    this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
                  this.atBottom = distance < 24
                })

                this.toBottom = () => {
                  // Paused means paused: a line arriving while the reader has
                  // stopped the stream must not move the viewport either.
                  const following = this.el.dataset.follow === "true"
                  if (following && this.atBottom) { this.el.scrollTop = this.el.scrollHeight }
                }

                this.toBottom()
              },

              updated() { this.toBottom() }
            }
          </script>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :click, :string, required: true
  attr :on, :boolean, required: true
  attr :icon, :string, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true

  defp toggle(assigns) do
    ~H"""
    <button
      phx-click={@click}
      title={@title}
      class={[
        "inline-flex h-8 items-center gap-1.5 rounded-md border px-2.5 text-xs",
        @on && "border-primary bg-primary/10 text-primary",
        !@on && "border-border hover:bg-accent hover:text-accent-foreground"
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {render_slot(@inner_block)}
    </button>
    """
  end
end
