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
  Refreshes the item in Plex, then polls until what Plex serves changes or the
  budget runs out.

  Returns `{:ok, before, after}` so the caller can say whether anything moved.
  `before` is `nil` when the pre-refresh read failed; the refresh still went
  ahead, since a read failure is no reason to withhold it.
  """
  @spec refresh_and_reread(map(), String.t()) ::
          {:ok, state() | nil, state()} | {:error, term()}
  def refresh_and_reread(config, rating_key) do
    before =
      case read(config, rating_key) do
        {:ok, state} -> state
        {:error, _reason} -> nil
      end

    with :ok <- Client.impl().refresh_metadata(config, rating_key),
         {:ok, current} <- poll(config, rating_key, before, poll_delays()) do
      {:ok, before, current}
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
  def verdict(%{origin: :none}, %{local_theme_present: true} = item) do
    {:warning,
     """
     Plex refreshed the item and still reports no theme, even though \
     #{Path.basename(item.local_theme_path || "theme.mp3")} is on disk beside it. \
     Either Plex is not reading local assets for this library, or the file is \
     not in the folder Plex scans for this item — compare the path above with \
     the folder Plex lists for the show, further down this page.\
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
  """
  @spec changed?(state() | nil, state()) :: boolean()
  def changed?(nil, _current), do: false
  def changed?(before, current), do: before != current

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil
end
