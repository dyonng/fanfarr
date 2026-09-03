defmodule FanfarrWeb.SettingsLive.Index do
  @moduledoc """
  Plex connection, library enablement, and root folders.

  Values saved here override environment variables without a restart -- the
  pattern the stack's other services use. The Plex form has a test button that
  round-trips to the server before anything relies on the credentials.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  # Short and without retries: the answer is wanted now, and "no answer in five
  # seconds" is itself the answer.
  @probe_options [retry: false, receive_timeout: 5_000, connect_options: [timeout: 5_000]]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:test_result, nil)
     |> assign(:testing, false)
     |> assign(:browser, nil)
     |> assign(:folder_path, "")
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:plex_url, Fanfarr.Config.get("plex_url") || "")
    |> assign(:plex_token_set, Fanfarr.Config.get("plex_token") not in [nil, ""])
    |> assign(:path_mappings, Fanfarr.Config.get("path_mappings") || "")
    |> assign(:sections, Fanfarr.Library.list_sections!())
    |> assign(:root_folders, Fanfarr.Library.list_root_folders!())
    |> assign(:local_auth_bypass, Fanfarr.Accounts.AuthMode.bypass_enabled?())
  end

  # Both buttons submit the same form, distinguished by the button's value, so
  # "Test" sees what is typed rather than what was last saved -- testing before
  # saving is the whole point of a test button.
  @impl true
  def handle_event("plex_form", %{"intent" => "test"} = params, socket) do
    with {:ok, url} <- Fanfarr.Config.normalize_plex_url(params["plex_url"] || ""),
         {:ok, token} <- token_from(params) do
      config = %{base_url: url, token: token, req_options: @probe_options}

      {:noreply,
       socket
       |> assign(:testing, true)
       |> assign(:test_result, nil)
       # Off the LiveView process: a host that does not answer would otherwise
       # block this process past the client's 30s push timeout, and the client
       # responds to that by remounting the page.
       |> start_async(:plex_test, fn -> probe(config) end)}
    else
      {:error, :invalid_url} ->
        {:noreply, assign(socket, :test_result, {:error, "That is not a valid URL"})}

      {:error, :no_token} ->
        {:noreply, assign(socket, :test_result, {:error, "Enter a token first"})}
    end
  end

  def handle_event("plex_form", params, socket) do
    case Fanfarr.Config.normalize_plex_url(params["plex_url"] || "") do
      {:ok, url} ->
        Fanfarr.Settings.put_setting!("plex_url", url)

        # An empty token field means "keep what is stored" -- the token is
        # never echoed back into the form, so an untouched field must not
        # blank it.
        case String.trim(params["plex_token"] || "") do
          "" ->
            :ok

          token ->
            Fanfarr.Settings.put_setting!("plex_token", token)
            # So the System page starts scrubbing the new token immediately
            # rather than at the next health tick.
            Fanfarr.Diagnostics.Redactor.remember(token)
        end

        {:noreply, socket |> load() |> put_flash(:info, "Plex settings saved")}

      {:error, :invalid_url} ->
        {:noreply, put_flash(socket, :error, "That is not a valid URL")}
    end
  end

  def handle_event("save_paths", %{"path_mappings" => mappings}, socket) do
    Fanfarr.Settings.put_setting!("path_mappings", String.trim(mappings))
    {:noreply, socket |> load() |> put_flash(:info, "Path mappings saved")}
  end

  def handle_event("toggle_section", %{"id" => id}, socket) do
    section = Fanfarr.Library.get_section!(id)
    Fanfarr.Library.set_section_enabled!(section, !section.enabled)
    {:noreply, load(socket)}
  end

  def handle_event("toggle_local_auth_bypass", _params, socket) do
    Fanfarr.Accounts.AuthMode.set_bypass_enabled(!socket.assigns.local_auth_bypass)
    {:noreply, load(socket)}
  end

  def handle_event("add_root_folder", %{"path" => path} = params, socket) do
    case String.trim(path) do
      "" ->
        {:noreply, put_flash(socket, :error, "Path cannot be empty")}

      path ->
        case Fanfarr.Library.create_root_folder(%{
               path: path,
               label: String.trim(params["label"] || ""),
               kind: String.to_existing_atom(params["kind"] || "any")
             }) do
          {:ok, folder} ->
            check_root_folder(folder)

            {:noreply,
             socket |> assign(:folder_path, "") |> load() |> put_flash(:info, "Root folder added")}

          {:error, _error} ->
            {:noreply,
             put_flash(socket, :error, "Could not add that root folder (already present?)")}
        end
    end
  end

  def handle_event("delete_root_folder", %{"id" => id}, socket) do
    id |> Fanfarr.Library.get_root_folder!() |> Fanfarr.Library.delete_root_folder!()
    {:noreply, socket |> load() |> put_flash(:info, "Root folder removed")}
  end

  # --- folder browser --------------------------------------------------------
  #
  # Browse the container's filesystem to the mount, Sonarr-style, instead of
  # typing a path and finding out on the first write that it was wrong.

  def handle_event("browse", params, socket) do
    path = params["path"] || socket.assigns.folder_path

    path =
      case String.trim(path || "") do
        "" -> "/"
        p -> p
      end

    browser =
      case Fanfarr.FileBrowser.list(path) do
        {:ok, listing} -> Map.put(listing, :error, nil)
        {:error, reason} -> %{path: path, parent: Path.dirname(path), dirs: [], error: reason}
      end

    {:noreply, assign(socket, :browser, browser)}
  end

  def handle_event("pick_folder", %{"path" => path}, socket) do
    {:noreply, socket |> assign(:folder_path, path) |> assign(:browser, nil)}
  end

  def handle_event("close_browser", _params, socket) do
    {:noreply, assign(socket, :browser, nil)}
  end

  def handle_event("recheck_root_folders", _params, socket) do
    Enum.each(socket.assigns.root_folders, &check_root_folder/1)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_async(:plex_test, {:ok, result}, socket) do
    {:noreply, socket |> assign(:testing, false) |> assign(:test_result, result)}
  end

  def handle_async(:plex_test, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:testing, false)
     |> assign(:test_result, {:error, "Test crashed: #{inspect(reason, limit: 5)}"})}
  end

  defp probe(config) do
    case Fanfarr.Plex.Client.impl().server_info(config) do
      {:ok, info} -> {:ok, "Connected to #{info.name} (Plex #{info.version})"}
      {:error, :unauthorized} -> {:error, "Plex rejected the token"}
      {:error, %{reason: reason}} -> {:error, "Connection failed: #{explain(reason)}"}
      {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  defp explain(:econnrefused), do: "connection refused (is that the right port?)"
  defp explain(:nxdomain), do: "host not found (from inside the container)"
  defp explain(:timeout), do: "timed out (no route from the container to that host?)"
  defp explain(:ehostunreach), do: "host unreachable from the container"
  defp explain(other), do: inspect(other)

  defp token_from(params) do
    case String.trim(params["plex_token"] || "") do
      "" ->
        case Fanfarr.Config.get("plex_token") do
          nil -> {:error, :no_token}
          "" -> {:error, :no_token}
          stored -> {:ok, stored}
        end

      typed ->
        {:ok, typed}
    end
  end

  # Health is observed, not trusted from configuration: a root that stops
  # resolving is the difference between "nothing to do" and "the mount is
  # gone", and this is where that becomes visible.
  defp check_root_folder(folder) do
    accessible = File.dir?(folder.path)

    writable =
      accessible and
        match?(
          {:ok, %{access: access}} when access in [:read_write, :write],
          File.stat(folder.path)
        )

    Fanfarr.Library.record_root_folder_check!(folder, %{
      accessible: accessible,
      writable: writable
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={:settings}
      current_user={@current_user}
      queue_summary={@queue_summary}
    >
      <div class="max-w-3xl space-y-6">
        <h1 class="text-2xl font-semibold tracking-tight">Settings</h1>

        <section class="rounded-lg border border-border bg-card p-4">
          <h2 class="text-sm font-semibold text-card-foreground">Plex</h2>
          <p class="mt-1 text-xs text-muted-foreground">
            Values here override PLEX_URL / PLEX_TOKEN from the environment.
          </p>
          <form id="plex-form" phx-submit="plex_form" class="mt-4 space-y-3">
            <div>
              <label class="text-xs font-medium text-muted-foreground">Server URL</label>
              <input
                type="text"
                name="plex_url"
                value={@plex_url}
                placeholder="http://host.docker.internal:32400"
                spellcheck="false"
                class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
              />
            </div>
            <div>
              <label class="text-xs font-medium text-muted-foreground">
                Token {if @plex_token_set, do: "(set — leave blank to keep)", else: ""}
              </label>
              <input
                type="password"
                name="plex_token"
                placeholder={if @plex_token_set, do: "••••••••", else: "X-Plex-Token"}
                autocomplete="off"
                class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
              />
            </div>
            <div class="flex items-center gap-2">
              <button
                name="intent"
                value="save"
                class="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
              >
                Save
              </button>
              <button
                name="intent"
                value="test"
                disabled={@testing}
                class="inline-flex h-9 items-center gap-2 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground disabled:opacity-60"
              >
                <.icon :if={@testing} name="lucide-loader-circle" class="size-4 animate-spin" />
                {if @testing, do: "Testing…", else: "Test connection"}
              </button>
              <span :if={@test_result} class="text-sm">
                <span
                  :if={match?({:ok, _}, @test_result)}
                  class="text-emerald-600 dark:text-emerald-400"
                >
                  {elem(@test_result, 1)}
                </span>
                <span :if={match?({:error, _}, @test_result)} class="text-destructive">
                  {elem(@test_result, 1)}
                </span>
              </span>
            </div>
          </form>
        </section>

        <section class="rounded-lg border border-border bg-card p-4">
          <h2 class="text-sm font-semibold text-card-foreground">Libraries</h2>
          <p class="mt-1 text-xs text-muted-foreground">
            Disabled by default: uploads cannot be undone, so each library is opt-in.
            Sync from the Library page discovers new ones.
          </p>
          <div :if={@sections == []} class="mt-4 text-sm text-muted-foreground">
            None discovered yet — configure Plex above, then Sync from the Library page.
          </div>
          <ul class="mt-3 divide-y divide-border/60">
            <li :for={s <- @sections} class="flex items-center justify-between py-2">
              <div>
                <p class="text-sm font-medium">{s.title}</p>
                <p class="text-xs text-muted-foreground">
                  {if s.kind == :show, do: "Series", else: "Movies"} · plex key {s.plex_key}
                </p>
              </div>
              <button
                phx-click="toggle_section"
                phx-value-id={s.id}
                class={[
                  "rounded-full px-3 py-1 text-xs font-medium",
                  s.enabled && "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
                  !s.enabled && "bg-muted text-muted-foreground"
                ]}
              >
                {if s.enabled, do: "Enabled", else: "Disabled"}
              </button>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-border bg-card p-4">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold text-card-foreground">Root folders</h2>
            <button
              phx-click="recheck_root_folders"
              class="rounded-md border border-border px-2 py-1 text-xs hover:bg-accent hover:text-accent-foreground"
            >
              Re-check
            </button>
          </div>
          <p class="mt-1 text-xs text-muted-foreground">
            The container paths your libraries are mounted at (/tv1, /movies1 …), as in Sonarr.
            Items are located by directory name across these, and themes are written to the
            drive that actually holds the show.
          </p>
          <ul class="mt-3 divide-y divide-border/60">
            <li :for={rf <- @root_folders} class="flex items-center justify-between py-2">
              <div>
                <p class="font-mono text-sm">{rf.path}</p>
                <p class="text-xs text-muted-foreground">
                  {(rf.label != "" && rf.label) || rf.kind}
                  <span :if={rf.checked_at}>
                    · {if rf.accessible, do: "accessible", else: "NOT ACCESSIBLE"} · {if rf.writable,
                      do: "writable",
                      else: "read-only"}
                  </span>
                </p>
              </div>
              <button
                phx-click="delete_root_folder"
                phx-value-id={rf.id}
                data-confirm={"Remove #{rf.path}?"}
                class="rounded-md p-1.5 text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
              >
                <.icon name="lucide-trash-2" class="size-4" />
              </button>
            </li>
          </ul>
          <form
            id="root-folder-form"
            phx-submit="add_root_folder"
            class="mt-3 flex flex-wrap items-end gap-2"
          >
            <div class="flex">
              <input
                type="text"
                name="path"
                value={@folder_path}
                placeholder="/tv1"
                class="h-9 w-44 rounded-l-md border border-input bg-background px-3 font-mono text-sm"
              />
              <button
                type="button"
                phx-click="browse"
                phx-value-path={@folder_path}
                class="h-9 rounded-r-md border border-l-0 border-input px-2 text-xs hover:bg-accent hover:text-accent-foreground"
                title="Browse the container's filesystem"
              >
                <.icon name="lucide-folder-open" class="size-4" />
              </button>
            </div>
            <input
              type="text"
              name="label"
              placeholder="label (optional)"
              class="h-9 w-40 rounded-md border border-input bg-background px-3 text-sm"
            />
            <select name="kind" class="h-9 rounded-md border border-input bg-background px-2 text-sm">
              <option value="any">Any</option>
              <option value="show">Series</option>
              <option value="movie">Movies</option>
            </select>
            <button class="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90">
              Add
            </button>
          </form>
        </section>

        <section class="rounded-lg border border-border bg-card p-4">
          <h2 class="text-sm font-semibold text-card-foreground">Path mappings</h2>
          <p class="mt-1 text-xs text-muted-foreground">
            Only for prefixes root folders cannot cover. plex_prefix:local_prefix pairs,
            separated by semicolons; longest match wins.
          </p>
          <form id="path-mappings-form" phx-submit="save_paths" class="mt-3 flex gap-2">
            <input
              type="text"
              name="path_mappings"
              value={@path_mappings}
              placeholder="/media/merged-storage/TV:/tv"
              class="h-9 flex-1 rounded-md border border-input bg-background px-3 font-mono text-sm"
            />
            <button class="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90">
              Save
            </button>
          </form>
        </section>

        <section class="rounded-lg border border-border bg-card p-4">
          <h2 class="text-sm font-semibold text-card-foreground">Authentication</h2>
          <p class="mt-1 text-xs text-muted-foreground">
            Skip sign-in for requests from a local address (loopback, 10/8, 172.16/12,
            192.168/16, link-local) — the same convenience Sonarr and Radarr offer. Checked
            against the actual connection, not a header, so it cannot be spoofed from outside.
            If Fanfarr sits behind a reverse proxy, this is the proxy's own address.
          </p>
          <div class="mt-3 flex items-center justify-between">
            <p class="text-sm font-medium">Disable authentication for local addresses</p>
            <button
              phx-click="toggle_local_auth_bypass"
              class={[
                "rounded-full px-3 py-1 text-xs font-medium",
                @local_auth_bypass && "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
                !@local_auth_bypass && "bg-muted text-muted-foreground"
              ]}
            >
              {if @local_auth_bypass, do: "Enabled", else: "Disabled"}
            </button>
          </div>
        </section>
      </div>

      <div
        :if={@browser}
        id="folder-browser"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
        phx-window-keydown="close_browser"
        phx-key="Escape"
      >
        <div class="w-full max-w-lg rounded-lg border border-border bg-card shadow-lg">
          <div class="flex items-center justify-between border-b border-border px-4 py-3">
            <div class="min-w-0">
              <h3 class="text-sm font-semibold">Choose a folder</h3>
              <p class="truncate font-mono text-xs text-muted-foreground" title={@browser.path}>
                {@browser.path}
              </p>
            </div>
            <button
              phx-click="close_browser"
              class="rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-accent-foreground"
              aria-label="Close"
            >
              <.icon name="lucide-x" class="size-4" />
            </button>
          </div>
          <p :if={@browser.error} class="px-4 py-3 text-sm text-destructive">
            Cannot read {@browser.path}: {inspect(@browser.error)}
          </p>
          <ul class="max-h-80 overflow-y-auto py-1 text-sm">
            <li :if={@browser.parent}>
              <button
                phx-click="browse"
                phx-value-path={@browser.parent}
                class="flex w-full items-center gap-2 px-4 py-1.5 text-left text-muted-foreground hover:bg-accent hover:text-accent-foreground"
              >
                <.icon name="lucide-corner-left-up" class="size-4" /> ..
              </button>
            </li>
            <li :for={dir <- @browser.dirs}>
              <button
                phx-click="browse"
                phx-value-path={dir.path}
                class="flex w-full items-center gap-2 px-4 py-1.5 text-left hover:bg-accent hover:text-accent-foreground"
              >
                <.icon name="lucide-folder" class="size-4 text-muted-foreground" /> {dir.name}
              </button>
            </li>
            <li
              :if={@browser.dirs == [] and is_nil(@browser.error)}
              class="px-4 py-3 text-muted-foreground"
            >
              No subfolders.
            </li>
          </ul>
          <div class="flex items-center justify-end gap-2 border-t border-border px-4 py-3">
            <button
              phx-click="close_browser"
              class="h-8 rounded-md border border-border px-3 text-xs hover:bg-accent hover:text-accent-foreground"
            >
              Cancel
            </button>
            <button
              phx-click="pick_folder"
              phx-value-path={@browser.path}
              class="h-8 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
            >
              Use this folder
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
