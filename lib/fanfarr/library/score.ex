defmodule Fanfarr.Library.Score do
  @moduledoc """
  Reading and presenting the critic and audience scores Plex holds.

  These are the *external* scores an agent fetched -- Rotten Tomatoes, TMDB,
  IMDb -- carried in `rating` and `audienceRating`, with the provider named in
  `ratingImage` / `audienceRatingImage` (strings shaped like
  `rottentomatoes://image.rating.ripe`). Plex's `userRating`, which is the
  operator's own star rating of a title, is deliberately not read: it is an
  opinion about the item rather than a fact about how it was received, and it
  would be the only column on the page that meant something different per
  install.

  ## One format, whatever the source

  Plex puts every provider on a 0-10 float, which is what makes them sortable
  against each other, and that is what is stored. They are all shown as
  percentages.

  Showing each provider's native form instead -- 87% for Rotten Tomatoes but
  8.3 for IMDb -- was faithful to each service and wrong for the column:
  which format a row got depended on which agent happened to know that title,
  so the same page carried two scales and a sorted column read as though it
  were not sorted. A single scale is worth more here than each service's
  house style, because the column exists to be compared down rather than read
  one row at a time.

  Which provider a score comes from is per-item, not per-server: Plex's movie
  agent commonly supplies Rotten Tomatoes while a TV agent supplies TMDB, and
  an item its agent knows nothing about supplies neither. Nothing here treats
  an absent score as an error.
  """

  @doc """
  The provider name out of a Plex rating-image string, or nil.

  `"rottentomatoes://image.rating.ripe"` is the shape; only the scheme
  identifies the provider, the rest describes which icon to draw.
  """
  @spec provider(term()) :: String.t() | nil
  def provider(image) when is_binary(image) do
    case String.split(image, "://", parts: 2) do
      [scheme, _rest] when scheme != "" -> scheme
      _ -> nil
    end
  end

  def provider(_), do: nil

  @doc """
  A score as a percentage, whichever service it came from.

  Returns nil for a missing score so callers can render an empty cell rather
  than a zero, which would read as a damning review rather than as no data.
  """
  @spec format(number() | nil) :: String.t() | nil
  def format(nil), do: nil

  # Plex sends a whole number as a JSON integer, so this cannot assume a float.
  def format(score), do: "#{round(score * 10)}%"

  @doc """
  The score on the 0-10 scale Plex stores it on, for a tooltip.

  Worth showing there because it is the number Plex's own UI displays, so
  anyone cross-checking a row against Plex is comparing like with like.
  """
  @spec out_of_ten(number() | nil) :: String.t() | nil
  def out_of_ten(nil), do: nil
  def out_of_ten(score), do: :erlang.float_to_binary(score / 1, decimals: 1)

  @doc """
  A short label for the service, for a tooltip.
  """
  @spec label(String.t() | nil) :: String.t()
  def label("rottentomatoes"), do: "Rotten Tomatoes"
  def label("themoviedb"), do: "TMDB"
  def label("thetvdb"), do: "TVDB"
  def label("imdb"), do: "IMDb"
  def label(nil), do: "an unnamed source"
  def label(other), do: other
end
