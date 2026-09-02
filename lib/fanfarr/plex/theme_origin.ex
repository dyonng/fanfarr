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
    * `metadata://themes/<sha>`            -- a local asset Plex picked up
    * `upload://themes/<sha>`              -- uploaded through the API

  The agent id is the whole difference between the first two, and missing it
  cost us an afternoon: every `metadata://` key was read as agent-supplied,
  so a library that had just picked up our own `theme.mp3` was reported as
  serving Plex's own theme instead. Two observations from the same server
  separate them -- an agent theme carries `tv.plex.agents.series_` before the
  digest, and a theme picked up from a `theme.mp3` we had written carries a
  bare 40-character digest and nothing else.

  ## Confidence

  The agent-prefixed form is **verified**. The bare-digest form is **strongly
  indicated**: it appeared on an item whose local `theme.mp3` had just started
  playing, in a library with "Use local assets" on, and it is the only form
  seen there. What is certain is narrower and is what the code actually keys
  on -- a bare digest names no agent, so it is not agent-supplied. `upload://`
  is **inferred** from Plex's convention for uploaded posters and art; we have
  still not uploaded a theme and read the result back.

  An unrecognised scheme returns `:unknown` rather than being guessed at, and
  themes *we* applied are known from our own application log regardless.
  """

  @type t :: :plex_agent | :local | :uploaded | :unknown

  @doc """
  Classifies a theme's `ratingKey`.

      iex> Fanfarr.Plex.ThemeOrigin.classify("metadata://themes/tv.plex.agents.series_b008")
      :plex_agent

      iex> Fanfarr.Plex.ThemeOrigin.classify("metadata://themes/46f33324b3bba73680ef38c5de0cd89664a55a1c")
      :local

      iex> Fanfarr.Plex.ThemeOrigin.classify("upload://themes/deadbeef")
      :uploaded

      iex> Fanfarr.Plex.ThemeOrigin.classify(nil)
      :unknown
  """
  @spec classify(String.t() | nil) :: t()
  def classify("metadata://themes/" <> rest) do
    if bare_digest?(rest), do: :local, else: :plex_agent
  end

  def classify("upload://" <> _), do: :uploaded
  def classify(_), do: :unknown

  # No agent id, just the digest. Hex-only is what makes this safe to key on:
  # an agent id contains dots and an underscore, neither of which can appear
  # here, so the two forms cannot be confused for one another.
  defp bare_digest?(rest), do: rest =~ ~r/^[0-9a-f]{8,}$/i

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

  Plex allows several themes per item and marks one `selected="1"`.

  Nothing marked means nothing is being served, and this returns `nil` for
  that. It used to fall back to the first entry on the theory that the first
  is what plays; a live item disproved it -- one theme listed, none marked,
  and the item's own `theme` attribute empty. The fallback turned "Plex has
  found your file but is not playing it" into a confident report of a theme
  that was not there. Use `listed_not_selected?/1` for that state instead.
  """
  @spec selected([map()]) :: map() | nil
  def selected(themes) when is_list(themes), do: Enum.find(themes, & &1[:selected])
  def selected(_), do: nil

  @doc """
  True when Plex has themes for the item but is serving none of them.

  The state a newly written `theme.mp3` lands in when the scanner has seen it
  and nothing has yet promoted it to the item's theme.
  """
  @spec listed_not_selected?([map()]) :: boolean()
  def listed_not_selected?(themes) when is_list(themes),
    do: themes != [] and selected(themes) == nil

  def listed_not_selected?(_), do: false
end
