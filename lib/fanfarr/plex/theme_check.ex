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

      {:ok,
       %{
         url: blank_to_nil(meta["theme"]),
         origin: (selected && selected.origin) || :none,
         agent: selected && selected[:agent],
         rating_key: selected && selected[:rating_key],
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
  A plain reading of what came back, for the operator.

  The severity is the honest one: `:ok` only when Plex is serving something
  that is not its own agent's theme, `:warning` when the local file demonstrably
  did not win, `:info` when the answer is real but not conclusive.

  `item` supplies whether Fanfarr wrote a file at all -- "no theme" means
  something quite different depending on that.
  """
  @spec verdict(state(), map()) :: {:ok | :warning | :info, String.t()}
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
     Plex scanned the folder and refreshed the item, and still reports no \
     theme, even though #{Path.basename(item.local_theme_path || "theme.mp3")} \
     is on disk beside it. The remaining explanations are that this library's \
     agent is not reading local assets, or that the folder Plex scanned is not \
     the folder we wrote to — compare the path above with the one Plex reports \
     further down this page.\
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
