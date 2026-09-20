defmodule Fanfarr.Library.SourceLinks do
  @moduledoc """
  Where an item's external ids point, so the item page can link out.

  Every URL is built from the id and the kind, never from the title, because
  two of the three sites need a slug and a title is not one:

    * **IMDb** takes the id bare -- `tt0120623` -- with no slug at all.

    * **TMDb** redirects `/movie/<id>` and `/tv/<id>` itself, to
      `/movie/9487-a-bug-s-life` and so on. The id is enough and the title is
      never guessed at. Verified: both forms answer 301 with the canonical
      slug in `Location`.

    * **TheTVDB** is the awkward one. It needs a slug in the path:
      `/series/81189` is a 404, and a slug derived from the title breaks on
      any disambiguated show -- `/series/the-office-us` resolves while
      `/series/the-office-us-2005` is a 404, and there is no way to know which
      from here. Its `/dereferrer/` endpoint takes the id and issues that
      redirect itself: verified `/dereferrer/movie/708` ->
      `/movies/a-bugs-life` and `/dereferrer/series/81189` ->
      `/series/breaking-bad`. Same trade TMDb makes, for the same reason.

  The links open in a new tab: they leave the appliance for someone else's
  site, and that site should not get a handle on the page it came from.
  """

  @type link :: %{label: String.t(), href: String.t()}

  @doc """
  The links this item's ids support, in the order they are shown.

  Ids that are absent or blank contribute nothing -- Plex reports some of them
  as empty strings rather than nulls, and a blank id is not a page.
  """
  @spec for_item(map()) :: [link()]
  def for_item(item) do
    [
      imdb(Map.get(item, :imdb_id)),
      tmdb(Map.get(item, :tmdb_id), Map.get(item, :kind)),
      tvdb(Map.get(item, :tvdb_id), Map.get(item, :kind))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp imdb(raw) do
    case present(raw) do
      nil ->
        nil

      id ->
        id = with_tt_prefix(id)
        %{label: "imdb:#{id}", href: "https://www.imdb.com/title/#{id}/"}
    end
  end

  defp tmdb(raw, kind) do
    case present(raw) do
      nil ->
        nil

      id ->
        %{
          label: "tmdb:#{id}",
          href: "https://www.themoviedb.org/#{if kind == :show, do: "tv", else: "movie"}/#{id}"
        }
    end
  end

  defp tvdb(raw, kind) do
    case present(raw) do
      nil ->
        nil

      id ->
        %{
          label: "tvdb:#{id}",
          href:
            "https://www.thetvdb.com/dereferrer/#{if kind == :show, do: "series", else: "movie"}/#{id}"
        }
    end
  end

  # Blank as well as absent. Plex reports these as empty strings often enough
  # to matter, and a whitespace-only id is not a page on anyone's site.
  defp present(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_id), do: nil

  # Both shapes turn up: Plex stores `tt0120623`, some sources store the digits
  # alone. IMDb wants the prefix and a zero-padded seven-digit body, so the
  # digits are padded rather than trusted.
  defp with_tt_prefix("tt" <> _rest = id), do: id

  defp with_tt_prefix(digits) do
    "tt" <> String.pad_leading(digits, 7, "0")
  end
end
