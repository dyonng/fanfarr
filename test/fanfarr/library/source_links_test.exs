defmodule Fanfarr.Library.SourceLinksTest do
  @moduledoc """
  The outbound links on the item page, including the two sites that need a
  slug they have to derive themselves.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Library.SourceLinks

  test "a movie links to all three sources" do
    # A Bug's Life, whose ids the item page shows.
    links =
      SourceLinks.for_item(%{imdb_id: "tt0120623", tmdb_id: "9487", tvdb_id: "708", kind: :movie})

    assert links == [
             %{label: "imdb:tt0120623", href: "https://www.imdb.com/title/tt0120623/"},
             %{label: "tmdb:9487", href: "https://www.themoviedb.org/movie/9487"},
             %{label: "tvdb:708", href: "https://www.thetvdb.com/dereferrer/movie/708"}
           ]
  end

  test "a show uses the television paths, not the film ones" do
    links =
      SourceLinks.for_item(%{
        imdb_id: "tt0903747",
        tmdb_id: "1396",
        tvdb_id: "81189",
        kind: :show
      })

    assert Enum.map(links, & &1.href) == [
             "https://www.imdb.com/title/tt0903747/",
             "https://www.themoviedb.org/tv/1396",
             "https://www.thetvdb.com/dereferrer/series/81189"
           ]
  end

  test "an imdb id stored as bare digits gets the prefix and padding" do
    # Plex stores tt0120623; other sources store 120623, and IMDb needs the
    # seven-digit body.
    assert [%{href: href}] = SourceLinks.for_item(%{imdb_id: "120623", kind: :movie})
    assert href == "https://www.imdb.com/title/tt0120623/"
  end

  test "ids that are absent or blank contribute no link" do
    # Plex reports some of these as empty strings rather than nulls.
    assert SourceLinks.for_item(%{imdb_id: nil, tmdb_id: "", tvdb_id: "  ", kind: :show}) == []
    assert SourceLinks.for_item(%{kind: :show}) == []
  end

  test "the links that are present survive a partially identified item" do
    links = SourceLinks.for_item(%{imdb_id: nil, tmdb_id: "1396", tvdb_id: nil, kind: :show})

    assert links == [
             %{label: "tmdb:1396", href: "https://www.themoviedb.org/tv/1396"}
           ]
  end
end
