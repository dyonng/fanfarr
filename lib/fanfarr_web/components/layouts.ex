defmodule FanfarrWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FanfarrWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_path, :atom,
    default: nil,
    doc: "which sidebar entry to highlight: :library, :activity, :settings, :system or :logs"

  attr :current_user, :map, default: nil, doc: "the signed-in user, when there is one"

  attr :queue_summary, :map,
    default: nil,
    doc: "counts from Fanfarr.Jobs.summary/0, kept current by FanfarrWeb.QueueStatus"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-background text-foreground">
      <%!-- Sidebar: the *arr convention -- persistent, dark, icon + label.
      Width and every label in it answer to [data-sidebar] on <html>, set
      before first paint by the script in root.html.heex -- the same
      mechanism the theme toggle uses, so there is no flash of the wrong
      width and no LiveView round trip to collapse it. --%>
      <aside class="fixed inset-y-0 left-0 z-40 flex w-52 flex-col border-r border-border bg-sidebar text-sidebar-foreground transition-[width] [[data-sidebar=collapsed]_&]:w-14">
        <div class="flex h-14 items-center justify-between gap-2 border-b border-border px-4 [[data-sidebar=collapsed]_&]:justify-center [[data-sidebar=collapsed]_&]:px-0">
          <a
            href={~p"/"}
            class="flex items-center gap-2 [[data-sidebar=collapsed]_&]:gap-0"
          >
            <%!-- The drawn mark rather than the emoji it replaced: an emoji renders
            in whatever the viewer's system font decides, so the brand changed
            shape between platforms and vanished where the glyph was missing.
            Same file as the favicon, so tab and sidebar cannot drift apart. --%>
            <img
              src={"/favicon.svg?v=#{Fanfarr.Version.asset_version()}"}
              alt=""
              aria-hidden="true"
              class="size-5"
            />
            <span class="text-base font-semibold tracking-tight [[data-sidebar=collapsed]_&]:hidden">
              Fanfarr
            </span>
          </a>
          <button
            phx-click={JS.dispatch("phx:toggle-sidebar")}
            class="rounded-md p-1.5 text-muted-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground [[data-sidebar=collapsed]_&]:hidden"
            title="Collapse sidebar"
          >
            <.icon name="lucide-panel-left-close" class="size-4" />
          </button>
          <button
            phx-click={JS.dispatch("phx:toggle-sidebar")}
            class="hidden rounded-md p-1.5 text-muted-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground [[data-sidebar=collapsed]_&]:block"
            title="Expand sidebar"
          >
            <.icon name="lucide-panel-left-open" class="size-4" />
          </button>
        </div>

        <nav class="flex-1 space-y-1 px-2 py-3">
          <.nav_link
            navigate={~p"/"}
            icon="lucide-clapperboard"
            label="Library"
            current={@current_path == :library}
          />
          <.nav_link
            navigate={~p"/activity"}
            icon="lucide-zap"
            label="Activity"
            current={@current_path == :activity}
          />
          <.nav_link
            navigate={~p"/system"}
            icon="lucide-activity"
            label="System"
            current={@current_path == :system}
            badge={health_badge()}
          />
          <.nav_link
            navigate={~p"/logs"}
            icon="lucide-logs"
            label="Logs"
            current={@current_path == :logs}
          />
          <.nav_link
            navigate={~p"/settings"}
            icon="lucide-settings"
            label="Settings"
            current={@current_path == :settings}
          />
        </nav>

        <div class="border-t border-border p-2">
          <div
            class="px-2 pb-1 pt-0.5 font-mono text-[11px] leading-none text-muted-foreground [[data-sidebar=collapsed]_&]:hidden"
            title={"Fanfarr #{Fanfarr.Version.display()}"}
          >
            {Fanfarr.Version.display()}
          </div>
          <div class="flex items-center justify-end px-2 py-1 [[data-sidebar=collapsed]_&]:justify-center">
            <a
              :if={assigns[:current_user]}
              href={~p"/sign-out"}
              class="rounded-md p-2 text-muted-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
              title="Sign out"
            >
              <.icon name="lucide-log-out" class="size-4" />
            </a>
          </div>
        </div>
      </aside>

      <div class="flex flex-1 flex-col pl-52 transition-[padding] [[data-sidebar=collapsed]_&]:pl-14">
        <main class="flex-1 px-6 py-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <%!-- Bottom right, and only when there is something to say. Clicking a
    button queues an Oban job and the page is then free to be navigated away
    from -- but nothing said so, and a spinner on the page you started from is
    not a queue. Hidden on Activity, which is the queue in full. --%>
    <.link
      :if={@queue_summary && @current_path != :activity && Fanfarr.Jobs.busy?(@queue_summary)}
      navigate={~p"/activity"}
      class="fixed bottom-4 right-4 z-50 flex items-center gap-2 rounded-full border border-border bg-card px-3 py-2 text-xs shadow-lg hover:bg-accent hover:text-accent-foreground"
      title="What the background queue is doing"
    >
      <.icon
        :if={@queue_summary.running > 0}
        name="lucide-loader-circle"
        class="size-3.5 animate-spin text-primary"
      />
      <.icon :if={@queue_summary.running == 0} name="lucide-clock" class="size-3.5" />
      <span>
        <span :if={@queue_summary.running > 0}>{@queue_summary.running} running</span>
        <span :if={@queue_summary.running > 0 and @queue_summary.queued > 0}> · </span>
        <span :if={@queue_summary.queued > 0}>{@queue_summary.queued} queued</span>
      </span>
    </.link>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :boolean, default: false
  attr :badge, :atom, default: nil, doc: "a health level to flag: :warning or :error"

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      title={@label}
      class={[
        "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
        "[[data-sidebar=collapsed]_&]:justify-center [[data-sidebar=collapsed]_&]:gap-0 [[data-sidebar=collapsed]_&]:px-0",
        @current && "bg-sidebar-accent text-sidebar-accent-foreground",
        !@current &&
          "text-muted-foreground hover:bg-sidebar-accent/60 hover:text-sidebar-accent-foreground"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      <span class="flex-1 [[data-sidebar=collapsed]_&]:hidden">{@label}</span>
      <span
        :if={@badge in [:warning, :error]}
        class={[
          "size-2 shrink-0 rounded-full",
          @badge == :error && "bg-destructive",
          @badge == :warning && "bg-amber-500"
        ]}
        title={if @badge == :error, do: "Something is not working", else: "Something needs attention"}
      />
    </.link>
    """
  end

  # The sidebar badge reads the monitor's last snapshot: nil before the first
  # run and when the monitor is idle (the test suite), which means no badge.
  defp health_badge do
    case Fanfarr.Health.Monitor.latest() do
      %{results: results} -> Fanfarr.Health.worst(results)
      _ -> nil
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <%!-- The stack, and the only thing that positions it. The generator left
    DaisyUI's `toast toast-top toast-end` on each flash and this project has
    no DaisyUI, so those classes resolved to nothing and every flash rendered
    inline at the end of the document -- off-screen on any page taller than
    the viewport, which is most of them. Positioning belongs here anyway: two
    flashes at once stack rather than landing on top of each other. --%>
    <div
      id={@id}
      aria-live="polite"
      class="fixed right-4 top-4 z-50 flex w-80 flex-col gap-2 sm:w-96"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="lucide-refresh-cw" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="lucide-refresh-cw" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border border-border bg-muted rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border border-border bg-background left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="lucide-monitor" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="lucide-sun" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="lucide-moon" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
