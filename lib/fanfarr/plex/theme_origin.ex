defmodule Fanfarr.Plex.ThemeOrigin do
  @moduledoc """
  Works out where a theme Plex is serving actually came from.

  This is the question behind the product: among the titles that *do* have a
  theme, which ones merely have Plex's own agent-supplied default, and which
  were put there deliberately? Presence alone cannot tell them apart.

  ## What the server actually reports

  Plex does **not** return a `provider` attribute on `/library/metadata/<id>/themes`.
  An earlier version of this code read one; it was always `nil`. Surveyed
  against Plex Media Server (`tv.plex.agents.series`), a theme element is:

      <Track
        key="/library/metadata/45870/file?url=metadata%3A%2F%2Fthemes%2Ftv%2Eplex%2Eagents%2Eseries_b008..."
        ratingKey="metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f"
        selected="1" />

  The origin is encoded in the `ratingKey`'s URI scheme, which is the same
  convention Plex uses for posters and art:

    * `metadata://themes/<agent-id>_<sha>` -- supplied by the named agent
    * `upload://themes/<sha>`              -- uploaded through the API

  ## Confidence

  `metadata://` is **verified** against a live server. `upload://` is
  **inferred** from Plex's established convention for uploaded posters and
  art; we have not yet uploaded a theme and read the result back. Confirm it
  on the first real upload and update this module.

  That asymmetry is deliberately safe. Everything the dashboard promises rests
  on recognising an agent-supplied theme, which is the verified case. An
  unrecognised scheme returns `:unknown` rather than being guessed at, and
  themes *we* applied are known from our own application log regardless.
  """

  @type t :: :plex_agent | :uploaded | :unknown

  @doc """
  Classifies a theme's `ratingKey`.

      iex> Fanfarr.Plex.ThemeOrigin.classify("metadata://themes/tv.plex.agents.series_b008")
      :plex_agent

      iex> Fanfarr.Plex.ThemeOrigin.classify("upload://themes/deadbeef")
      :uploaded

      iex> Fanfarr.Plex.ThemeOrigin.classify(nil)
      :unknown
  """
  @spec classify(String.t() | nil) :: t()
  def classify("metadata://themes/" <> _), do: :plex_agent
  def classify("upload://" <> _), do: :uploaded
  def classify(_), do: :unknown

  @doc """
  The agent that supplied a theme, when Plex names one.

  The agent id sits between the `themes/` prefix and the trailing `_<sha>`,
  e.g. `tv.plex.agents.series`. Useful for the item detail page, and for
  telling a stock Plex theme from one an older third-party agent left behind.

      iex> Fanfarr.Plex.ThemeOrigin.agent("metadata://themes/tv.plex.agents.series_b008ab")
      "tv.plex.agents.series"

      iex> Fanfarr.Plex.ThemeOrigin.agent("upload://themes/deadbeef")
      nil
  """
  @spec agent(String.t() | nil) :: String.t() | nil
  def agent("metadata://themes/" <> rest) do
    # Split on the *last* underscore: agent ids contain dots but the sha is
    # hex, so anything after the final underscore is the digest.
    case String.split(rest, "_") do
      [_single] -> nil
      parts -> parts |> Enum.drop(-1) |> Enum.join("_")
    end
  end

  def agent(_), do: nil

  @doc """
  Picks the theme Plex is actually serving out of the list it returns.

  Plex allows several themes per item and marks one `selected="1"`. When
  nothing is marked, the first is what plays.
  """
  @spec selected([map()]) :: map() | nil
  def selected([]), do: nil

  def selected(themes) when is_list(themes) do
    Enum.find(themes, hd(themes), & &1[:selected])
  end

  def selected(_), do: nil
end
