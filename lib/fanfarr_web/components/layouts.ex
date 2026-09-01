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
    doc: "which sidebar entry to highlight: :library, :activity or :settings"

  attr :current_user, :map, default: nil, doc: "the signed-in user, when there is one"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-background text-foreground">
      <%!-- Sidebar: the *arr convention -- persistent, dark, icon + label. --%>
      <aside class="fixed inset-y-0 left-0 z-40 flex w-52 flex-col border-r border-border bg-sidebar text-sidebar-foreground">
        <a href={~p"/"} class="flex h-14 items-center gap-2 border-b border-border px-4">
          <span class="text-lg" aria-hidden="true">🎺</span>
          <span class="text-base font-semibold tracking-tight">Fanfarr</span>
        </a>

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
            navigate={~p"/settings"}
            icon="lucide-settings"
            label="Settings"
            current={@current_path == :settings}
          />
        </nav>

        <div class="border-t border-border p-2">
          <div
            class="px-2 pb-1 pt-0.5 font-mono text-[11px] leading-none text-muted-foreground"
            title={"Fanfarr #{Fanfarr.Version.display()}"}
          >
            {Fanfarr.Version.display()}
          </div>
          <div class="flex items-center justify-between px-2 py-1">
            <.theme_toggle />
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

      <div class="flex flex-1 flex-col pl-52">
        <main class="flex-1 px-6 py-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
        @current && "bg-sidebar-accent text-sidebar-accent-foreground",
        !@current &&
          "text-muted-foreground hover:bg-sidebar-accent/60 hover:text-sidebar-accent-foreground"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
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
    <div id={@id} aria-live="polite">
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
