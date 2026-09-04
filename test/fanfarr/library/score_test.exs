defmodule Fanfarr.Library.ScoreTest do
  use ExUnit.Case, async: true

  alias Fanfarr.Library.Score

  describe "provider/1" do
    test "reads the service out of a Plex rating image" do
      assert Score.provider("rottentomatoes://image.rating.ripe") == "rottentomatoes"
      assert Score.provider("rottentomatoes://image.rating.upright") == "rottentomatoes"
      assert Score.provider("imdb://image.rating") == "imdb"
      assert Score.provider("themoviedb://image.rating") == "themoviedb"
    end

    test "anything that is not one of those is nothing, not a guess" do
      assert Score.provider(nil) == nil
      assert Score.provider("") == nil
      assert Score.provider("no-scheme-here") == nil
      assert Score.provider(42) == nil
    end
  end

  describe "format/2" do
    test "Rotten Tomatoes is a percentage, which is how anyone has ever seen it" do
      assert Score.format(8.3, "rottentomatoes") == "83%"
      assert Score.format(10.0, "rottentomatoes") == "100%"
      assert Score.format(0.7, "rottentomatoes") == "7%"
    end

    test "everyone else is out of ten" do
      assert Score.format(8.3, "imdb") == "8.3"
      assert Score.format(7.0, "themoviedb") == "7.0"
      assert Score.format(6.55, nil) == "6.5"
    end

    test "a whole number arrives as an integer and still formats" do
      assert Score.format(8, "imdb") == "8.0"
      assert Score.format(8, "rottentomatoes") == "80%"
    end

    test "no score is nothing rather than a zero" do
      # A zero would read as a damning review rather than as no data.
      assert Score.format(nil, "rottentomatoes") == nil
      assert Score.format(nil, nil) == nil
    end
  end

  test "label/1 names the service for a tooltip" do
    assert Score.label("rottentomatoes") == "Rotten Tomatoes"
    assert Score.label("themoviedb") == "TMDB"
    assert Score.label("imdb") == "IMDb"
    assert Score.label(nil) == "an unnamed source"
  end
end
