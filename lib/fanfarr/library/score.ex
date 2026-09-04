defmodule Fanfarr.Library.Score do
  @moduledoc """
  Reading and presenting the ratings Plex holds for an item.

  Plex normalises every provider onto a 0-10 float in `rating` and
  `audienceRating`, and names the provider in `ratingImage` /
  `audienceRatingImage` -- strings shaped like
  `rottentomatoes://image.rating.ripe` or `imdb://image.rating`. Storing the
  0-10 number is what lets a Rotten Tomatoes score and an IMDb one sort
  against each other at all.

  Presenting them on that scale would be wrong, though. A Rotten Tomatoes
  score is a percentage everywhere it is ever shown, and "8.3" for a film
  people know as 83% reads as a different number. So the scale is uniform in
  the database and native at the edge: percentages for Rotten Tomatoes,
  x.x for the out-of-ten providers.

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
  A score written the way the service that produced it writes it.

  Rotten Tomatoes is a percentage; everyone else is out of ten. Returns nil
  for a missing score so callers can render an empty cell rather than a zero,
  which would read as a damning review rather than as no data.
  """
  @spec format(number() | nil, String.t() | nil) :: String.t() | nil
  def format(nil, _source), do: nil

  def format(score, "rottentomatoes"), do: "#{round(score * 10)}%"

  # Plex sends a whole number as a JSON integer, so this cannot assume a float.
  def format(score, _source) do
    :erlang.float_to_binary(score / 1, decimals: 1)
  end

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
