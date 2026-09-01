defmodule FanfarrWeb.SettingsLive.Index do
  @moduledoc """
  Plex connection, library enablement, and root folders.

  Values saved here override environment variables without a restart -- the
  pattern the stack's other services use. The Plex form has a test button that
  round-trips to the server before anything relies on the credentials.
  """
  use FanfarrWeb, :live_view

  on_mount {FanfarrWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:test_result, nil)
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:plex_url, Fanfarr.Config.get("plex_url") || "")
    |> assign(:plex_token_set, Fanfarr.Config.get("plex_token") not in [nil, ""])
    |> assign(:path_mappings, Fanfarr.Config.get("path_mappings") || "")
    |> assign(:sections, Fanfarr.Library.list_sections!())
    |> assign(:root_folders, Fanfarr.Library.list_root_folders!())
  end

  @impl true
  def handle_event("save_plex", %{"plex_url" => url} = params, socket) do
    Fanfarr.Settings.put_setting!("plex_url", String.trim(url))

    # An empty token field means "keep what is stored" -- the token is never
    # echoed back into the form, so an untouched field must not blank it.
    case String.trim(params["plex_token"] || "") do
      "" -> :ok
      token -> Fanfarr.Settings.put_setting!("plex_token", token)
    end

    {:noreply, socket |> load() |> put_flash(:info, "Plex settings saved")}
  end

  def handle_event("test_plex", _params, socket) do
    result =
      with {:ok, config} <- Fanfarr.Config.plex_config(),
           {:ok, info} <- Fanfarr.Plex.Client.impl().server_info(config) do
        {:ok, "Connected to #{info.name} (#{info.version})"}
      else
        {:error, :plex_not_configured} -> {:error, "Set a URL and token first"}
        {:error, :unauthorized} -> {:error, "Plex rejected the token"}
        {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
      end

    {:noreply, assign(socket, :test_result, result)}
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
            {:noreply, socket |> load() |> put_flash(:info, "Root folder added")}

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

  def handle_event("recheck_root_folders", _params, socket) do
    Enum.each(socket.assigns.root_folders, &check_root_folder/1)
    {:noreply, load(socket)}
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
    <Layouts.app flash={@flash} current_path={:settings} current_user={@current_user}>
      <div class="max-w-3xl space-y-6">
        <h1 class="text-2xl font-semibold tracking-tight">Settings</h1>

        <section class="rounded-lg border border-border bg-card p-4">
          <h2 class="text-sm font-semibold text-card-foreground">Plex</h2>
          <p class="mt-1 text-xs text-muted-foreground">
            Values here override PLEX_URL / PLEX_TOKEN from the environment.
          </p>
          <form id="plex-form" phx-submit="save_plex" class="mt-4 space-y-3">
            <div>
              <label class="text-xs font-medium text-muted-foreground">Server URL</label>
              <input
                type="url"
                name="plex_url"
                value={@plex_url}
                placeholder="http://host.docker.internal:32400"
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
              <button class="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90">
                Save
              </button>
              <button
                type="button"
                phx-click="test_plex"
                class="h-9 rounded-md border border-border px-3 text-sm hover:bg-accent hover:text-accent-foreground"
              >
                Test connection
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
            <input
              type="text"
              name="path"
              placeholder="/tv1"
              class="h-9 w-40 rounded-md border border-input bg-background px-3 font-mono text-sm"
            />
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
      </div>
    </Layouts.app>
    """
  end
end
