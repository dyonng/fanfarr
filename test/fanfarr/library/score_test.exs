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

  describe "format/1" do
    test "every provider is shown on the same scale" do
      # Which format a row got used to depend on which agent happened to know
      # the title, so one column carried two scales and sorting it read as
      # though it had not sorted.
      assert Score.format(8.3) == "83%"
      assert Score.format(10.0) == "100%"
      assert Score.format(0.7) == "7%"
      assert Score.format(7.0) == "70%"
    end

    test "a whole number arrives as an integer and still formats" do
      assert Score.format(8) == "80%"
    end

    test "no score is nothing rather than a zero" do
      # A zero would read as a damning review rather than as no data.
      assert Score.format(nil) == nil
    end
  end

  describe "out_of_ten/1" do
    test "keeps Plex's own scale for the tooltip" do
      assert Score.out_of_ten(8.3) == "8.3"
      assert Score.out_of_ten(8) == "8.0"
      assert Score.out_of_ten(6.55) == "6.5"
      assert Score.out_of_ten(nil) == nil
    end
  end

  test "label/1 names the service for a tooltip" do
    assert Score.label("rottentomatoes") == "Rotten Tomatoes"
    assert Score.label("themoviedb") == "TMDB"
    assert Score.label("imdb") == "IMDb"
    assert Score.label(nil) == "an unnamed source"
  end
end
