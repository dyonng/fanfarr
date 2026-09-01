defmodule Fanfarr.Plex.ThemeOriginTest do
  use ExUnit.Case, async: true

  doctest Fanfarr.Plex.ThemeOrigin

  alias Fanfarr.Plex.ThemeOrigin

  # Copied verbatim from a live Plex Media Server survey, not invented. This is
  # the only shape we have actually seen, so it is the one the suite pins.
  @observed "metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f"

  describe "classify/1" do
    test "the observed agent theme is recognised" do
      assert ThemeOrigin.classify(@observed) == :plex_agent
    end

    test "an uploaded theme is recognised" do
      assert ThemeOrigin.classify("upload://themes/deadbeef") == :uploaded
    end

    test "anything unrecognised is :unknown rather than guessed at" do
      for key <- [nil, "", "themes/whatever", "http://example.com/a.mp3", 42] do
        assert ThemeOrigin.classify(key) == :unknown
      end
    end
  end

  describe "agent/1" do
    test "reads the agent id out of the observed key" do
      assert ThemeOrigin.agent(@observed) == "tv.plex.agents.series"
    end

    test "an agent id containing underscores keeps them" do
      assert ThemeOrigin.agent("metadata://themes/com.plexapp.agents.the_tvdb_abc123") ==
               "com.plexapp.agents.the_tvdb"
    end

    test "no agent for uploads or for a key with no digest" do
      assert ThemeOrigin.agent("upload://themes/deadbeef") == nil
      assert ThemeOrigin.agent("metadata://themes/bare") == nil
      assert ThemeOrigin.agent(nil) == nil
    end
  end

  describe "selected/1" do
    test "prefers the theme Plex marked selected" do
      chosen = %{rating_key: "upload://themes/x", selected: true}
      other = %{rating_key: @observed, selected: false}

      assert ThemeOrigin.selected([other, chosen]) == chosen
    end

    test "falls back to the first when Plex marks none" do
      first = %{rating_key: @observed, selected: false}

      assert ThemeOrigin.selected([first, %{rating_key: "b", selected: false}]) == first
    end

    test "no themes means nothing selected" do
      assert ThemeOrigin.selected([]) == nil
    end
  end
end
