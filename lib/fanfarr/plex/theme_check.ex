defmodule Fanfarr.Plex.ThemeCheck do
  @moduledoc """
  Asks Plex to refresh one item and then reads back what it actually serves as
  that item's theme.

  Writing `theme.mp3` beside the media is only half the job: Plex has to pick
  the file up, and whether it does is not ours to control. Telling Plex to
  refresh and then walking away -- which is what the item page used to do --
  leaves "it worked" and "it silently did nothing" looking exactly alike, and
  the operator with nothing to act on.

  So the refresh is followed by a read of `/library/metadata/<id>/themes`, and
  the result is reported verbatim: the ratingKeys Plex lists, which one is
  selected, and the agent named in it. `verdict/2` turns that into a sentence,
  but the raw list is kept and shown, because the shape of a *local* theme's
  ratingKey is the one case `Fanfarr.Plex.ThemeOrigin` has not been able to
  verify against a live server. When it turns up here, we will have it.

  ## Timing

  A refresh is asynchronous on the server: the PUT returns immediately and the
  scan happens behind it. The read is therefore polled a few times, stopping as
  soon as the state changes. A refresh that has not landed by the last poll
  reports the state as it stands rather than pretending to a conclusion.
  """

  require Logger

  alias Fanfarr.Plex.Client
  alias Fanfarr.Plex.ThemeOrigin

  # Roughly ten seconds in total. Long enough for a single-item refresh on a
  # healthy server, short enough to sit inside a page interaction. Configurable
  # so the suite does not have to sit through it.
  @default_poll_delays [2_000, 3_000, 5_000]

  @type state :: %{
          url: String.t() | nil,
          origin: ThemeOrigin.t() | :none,
          agent: String.t() | nil,
          rating_key: String.t() | nil,
          themes: [map()]
        }

  @doc """
  Reads the theme Plex currently serves for an item.

  `url` comes from the item's own metadata (the `theme` attribute, the same
  field a library sync stores); everything else comes from the themes listing,
  which is the only place the origin is visible.
  """
  @spec read(map(), String.t()) :: {:ok, state()} | {:error, term()}
  def read(config, rating_key) do
    with {:ok, meta} <- Client.impl().metadata(config, rating_key),
         {:ok, themes} <- Client.impl().themes(config, rating_key) do
      selected = ThemeOrigin.selected(themes)

      url = blank_to_nil(meta["theme"])

      # The item's own `theme` attribute is the authority on what is being
      # served. A themes listing can name files Plex has found and not
      # promoted, and reporting one of those as the item's theme is how
      # "Plex found your file but is not playing it" got mistaken for a theme
      # that was there.
      {:ok,
       %{
         url: url,
         origin: (url && selected && selected.origin) || :none,
         agent: url && selected && selected[:agent],
         rating_key: url && selected && selected[:rating_key],
         listed_not_selected: ThemeOrigin.listed_not_selected?(themes),
         themes: themes
       }}
    end
  end

  @doc """
  Scans the item's folder, refreshes the item, then polls until what Plex
  serves changes or the budget runs out.

  The scan is the part that matters and the part we were missing. Plex finds
  files and fetches metadata in two separate stages: the scanner walks the
  filesystem, and the agents then run over what it found. Refreshing an item
  only re-runs the agents, so a `theme.mp3` written since the last scan is
  simply not in the listing they work from -- they re-derive the same answer as
  before and Plex goes on reporting no theme. Asking the scanner to walk that
  one folder first is what puts the file in front of them.

  Returns `{:ok, before, after}` so the caller can say whether anything moved.
  `before` is `nil` when the pre-refresh read failed; the refresh still goes
  ahead, since a read failure is no reason to withhold it.

  `scan` is `{section_key, plex_dir}` -- both in Plex's own view of things --
  or `nil` when we do not know where Plex thinks the item lives, in which case
  only the metadata refresh runs.
  """
  @spec refresh_and_reread(map(), String.t(), {String.t(), String.t()} | nil) ::
          {:ok, state() | nil, state()} | {:error, term()}
  def refresh_and_reread(config, rating_key, scan \\ nil) do
    before =
      case read(config, rating_key) do
        {:ok, state} -> state
        {:error, _reason} -> nil
      end

    scanned = scan_folder(config, scan)

    with :ok <- Client.impl().refresh_metadata(config, rating_key),
         {:ok, current} <- poll(config, rating_key, before, poll_delays()) do
      {:ok, before, Map.put(current, :scanned, scanned)}
    end
  end

  # A scan failure is reported, not raised: the metadata refresh is still worth
  # doing, and which of the two steps ran is exactly what the operator needs to
  # know when the theme still does not appear.
  defp scan_folder(_config, nil), do: :not_attempted

  defp scan_folder(config, {section_key, dir}) do
    case Client.impl().scan_directory(config, section_key, dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp poll_delays,
    do: Application.get_env(:fanfarr, :plex_theme_poll_delays, @default_poll_delays)

  @doc """
  Tells Plex to serve one of the themes it already lists, then reads back what
  it actually serves.

  The read-back is the point. The endpoint is inferred from Plex's convention
  for posters, so a 200 is not on its own evidence that anything changed;
  `{:ok, state}` here means we asked and then looked.
  """
  @spec select(map(), String.t(), String.t()) :: {:ok, state()} | {:error, term()}
  def select(config, rating_key, theme_rating_key) do
    before =
      case read(config, rating_key) do
        {:ok, state} -> state
        {:error, _reason} -> nil
      end

    result = Client.impl().select_theme(config, rating_key, theme_rating_key)
    Logger.info("asked Plex to serve #{theme_rating_key} for #{rating_key}: #{inspect(result)}")

    with :ok <- result do
      # Polled rather than read once. Plex answers the request before it has
      # acted on it, and reading straight back reports a selection that has not
      # landed yet as a failure.
      poll(config, rating_key, before, poll_delays())
    end
  end

  @doc """
  Uploads a theme file to Plex, then reads back what it serves.

  The other way round from `select/3`. Selecting asks Plex to serve a theme it
  already knows about; uploading hands it the bytes and lets it own the result,
  which is what Themerr-plex did for years and does not depend on Plex being
  willing to promote a local asset. Worth having as a separate action because
  the two fail differently: selection is refused by the server, an upload is
  refused by the file.
  """
  @spec upload(map(), String.t(), Path.t()) :: {:ok, state()} | {:error, term()}
  def upload(config, rating_key, path) do
    before =
      case read(config, rating_key) do
        {:ok, state} -> state
        {:error, _reason} -> nil
      end

    result = Client.impl().upload_theme(config, rating_key, {:file, path})
    Logger.info("uploaded #{path} to Plex for #{rating_key}: #{inspect(result)}")

    with :ok <- result do
      poll(config, rating_key, before, poll_delays())
    end
  end

  defp poll(config, rating_key, before, [delay | rest]) do
    if delay > 0, do: Process.sleep(delay)

    case {read(config, rating_key), rest} do
      {{:ok, state}, _} when state != before -> {:ok, state}
      {{:ok, state}, []} -> {:ok, state}
      {{:error, reason}, []} -> {:error, reason}
      {_result, _rest} -> poll(config, rating_key, before, rest)
    end
  end

  @doc """
  Asks Plex the two questions left standing when a scan changes nothing:
  is this library set up to read local assets, and is the folder Plex has for
  the item the folder we wrote to.

  Everything here is a read, and everything is reported as Plex phrased it.
  The agent settings in particular are listed rather than interpreted: which
  preference governs theme music differs between the legacy agents and
  tv.plex.agents.*, and inventing a mapping we have not verified is how the
  earlier `provider` field got made up.
  """
  @spec diagnose(map(), map(), String.t()) :: map()
  def diagnose(config, item, section_key) do
    %{
      section: section_detail(config, section_key),
      prefs: prefs(config, section_key),
      plex_locations: locations(config, item.plex_rating_key),
      wrote_to: item.local_theme_path,
      plex_path: item.plex_path,
      seasons: seasons(config, item)
    }
  end

  # Reported because a pattern was noticed, not because we know it matters:
  # the shows that took a local theme all had more than one season, and the
  # ones that did not had one. That is a correlation across a handful of
  # items and there is no mechanism to explain it, so the count is put on the
  # page where it can be checked against more of them rather than being acted
  # on. `nil` for a movie, and for a show Plex will not enumerate.
  defp seasons(_config, %{kind: :movie}), do: nil

  defp seasons(config, item) do
    case Client.impl().raw(config, "/library/metadata/#{item.plex_rating_key}/children") do
      {:ok, body} ->
        # Both keys, because the JSON key is not the XML element name. Seasons
        # are <Directory> in XML and "Metadata" in JSON, the same trap that
        # made /themes look empty when it was read as <Track>. Reading only
        # "Directory" reported every show as having no seasons at all, which
        # is what this line was added to measure.
        body
        |> container(["Directory", "Metadata"])
        |> Enum.map(& &1["title"])
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        nil
    end
  end

  defp section_detail(config, section_key) do
    case Client.impl().raw(config, "/library/sections") do
      {:ok, body} ->
        body
        |> container("Directory")
        |> Enum.find(%{}, &(to_string(&1["key"]) == to_string(section_key)))
        |> Map.take(["title", "agent", "scanner", "language", "type"])

      {:error, reason} ->
        %{"error" => inspect(reason)}
    end
  end

  defp prefs(config, section_key) do
    case Client.impl().raw(config, "/library/sections/#{section_key}/prefs") do
      {:ok, body} ->
        body
        |> container("Setting")
        |> Enum.map(&%{id: &1["id"], label: &1["label"], value: &1["value"]})

      {:error, _reason} ->
        []
    end
  end

  defp locations(config, rating_key) do
    case Client.impl().raw(config, "/library/metadata/#{rating_key}") do
      {:ok, body} ->
        body
        |> container(["Directory", "Video", "Metadata"])
        |> Enum.flat_map(&List.wrap(&1["Location"]))
        |> Enum.map(& &1["path"])
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp container(body, names) when is_list(names) do
    c = body["MediaContainer"] || %{}
    Enum.flat_map(names, &List.wrap(Map.get(c, &1, [])))
  end

  defp container(body, name), do: container(body, [name])

  @doc """
  Preferences whose name mentions local assets.

  A filter over `diagnose/3`'s `prefs`. Kept separate so a page can lead with
  the likely ones and still show the rest.
  """
  @spec local_asset_prefs([map()]) :: [map()]
  def local_asset_prefs(prefs) do
    Enum.filter(prefs, fn pref ->
      text = String.downcase("#{pref.id} #{pref.label}")
      String.contains?(text, "local") or String.contains?(text, "theme")
    end)
  end

  @doc """
  Whether the library has "Use local assets" switched off.

  This is the setting that decides whether Plex reads sidecar files beside the
  media at all, `theme.mp3` among them. With it off, writing the file is
  wasted work: the scanner and the agents are both behaving correctly and are
  simply not looking, so a refresh reports no theme however many times it is
  run. Verified on a live server -- a library showing `false` here never
  picked up a theme.mp3 sitting in the right folder.

  Matched on the label as well as the id, since the id differs across agent
  generations while the label has been stable. `nil` when the library did not
  report the setting, which is not the same as it being on.
  """
  @spec local_assets_off?([map()]) :: boolean() | nil
  def local_assets_off?(prefs) do
    Enum.find_value(prefs, fn pref ->
      text = String.downcase("#{pref.id} #{pref.label}")

      if String.contains?(text, "local assets") or String.contains?(text, "localassets") do
        {:found, pref.value in [false, "false", 0, "0"]}
      end
    end)
    |> case do
      {:found, off?} -> off?
      nil -> nil
    end
  end

  @doc """
  A plain reading of what came back, for the operator.

  The severity is the honest one: `:ok` only when Plex is serving something
  that is not its own agent's theme, `:warning` when the local file demonstrably
  did not win, `:info` when the answer is real but not conclusive.

  `item` supplies whether Fanfarr wrote a file at all -- "no theme" means
  something quite different depending on that.
  """
  @spec verdict(state(), map()) :: {:ok | :warning | :info, String.t()}
  def verdict(%{origin: :local}, _item) do
    {:ok, "Plex is serving the local file — the theme Fanfarr wrote is the one playing."}
  end

  def verdict(%{origin: :none, listed_not_selected: true}, %{local_theme_present: true}) do
    {:warning,
     """
     Plex has found the file — it is in the item's theme list — but has not \
     made it the item's theme, so nothing plays. Use the "use this one" button \
     beside it below, which asks Plex to serve it.\
     """}
  end

  def verdict(%{origin: :none, scanned: {:error, reason}}, %{local_theme_present: true}) do
    {:warning,
     """
     Plex refused to scan the item's folder (#{inspect(reason)}), so it never \
     looked for the file. Without that scan a metadata refresh cannot see a \
     theme.mp3 added since the last one.\
     """}
  end

  def verdict(%{origin: :none, scanned: :not_attempted}, %{local_theme_present: true}) do
    {:warning,
     """
     Plex still reports no theme, and we could not ask it to scan the folder \
     because we do not know where Plex thinks this item lives. Sync the library \
     so the item's Plex path is known, then try again.\
     """}
  end

  def verdict(%{origin: :none}, %{local_theme_present: true} = item) do
    {:warning,
     """
     Plex accepted a scan of the folder, refreshed the item, and still reports \
     no theme, even though #{Path.basename(item.local_theme_path || "theme.mp3")} \
     is on disk beside it. Two things are left: this library's agent may not be \
     reading local assets, or the folder Plex holds for this item may not be \
     the one we wrote to. Run the check below and Plex will answer both.\
     """}
  end

  def verdict(%{origin: :none}, _item) do
    {:info, "Plex reports no theme for this item."}
  end

  def verdict(%{origin: :plex_agent, agent: agent}, %{local_theme_present: true}) do
    {:warning,
     """
     The file is on disk, but Plex is serving a theme from its own agent \
     (#{agent || "unnamed agent"}) instead. Plex chose between the two and did \
     not pick ours; which knob decides that depends on the library's agent, so \
     check the library's settings for whether local assets are preferred, and \
     whether this item's theme field is locked to the agent's value.\
     """}
  end

  def verdict(%{origin: :plex_agent, agent: agent}, _item) do
    {:info, "Plex is serving a theme from its own agent (#{agent || "unnamed agent"})."}
  end

  def verdict(%{origin: :uploaded}, _item) do
    {:ok, "Plex is serving an uploaded theme."}
  end

  def verdict(%{origin: :unknown, rating_key: key}, %{local_theme_present: true}) do
    {:ok,
     "Plex is serving a theme it does not attribute to an agent (#{key || "no ratingKey"}) — " <>
       "consistent with it having picked up the local file."}
  end

  def verdict(%{origin: :unknown, rating_key: key}, _item) do
    {:info, "Plex is serving a theme with an unrecognised ratingKey (#{key || "none"})."}
  end

  @doc """
  True when the refresh changed what Plex serves.

  Compares only the fields describing the theme. `:scanned` records which steps
  we took, not what Plex answered, and comparing it would report a change on
  every call.
  """
  @spec changed?(state() | nil, state()) :: boolean()
  def changed?(nil, _current), do: false

  def changed?(before, current) do
    Map.take(before, [:url, :origin, :agent, :rating_key]) !=
      Map.take(current, [:url, :origin, :agent, :rating_key])
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil
end
