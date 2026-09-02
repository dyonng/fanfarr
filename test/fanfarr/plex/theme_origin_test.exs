defmodule Fanfarr.Plex.ThemeOriginTest do
  use ExUnit.Case, async: true

  doctest Fanfarr.Plex.ThemeOrigin

  alias Fanfarr.Plex.ThemeOrigin

  # Copied verbatim from a live Plex Media Server survey, not invented. This is
  # the only shape we have actually seen, so it is the one the suite pins.
  @observed "metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f"

  # Also copied from the same server: the form that appeared on an item whose
  # local theme.mp3 had just started playing. No agent id, just the digest.
  @local "metadata://themes/46f33324b3bba73680ef38c5de0cd89664a55a1c"

  describe "classify/1" do
    test "the observed agent theme is recognised" do
      assert ThemeOrigin.classify(@observed) == :plex_agent
    end

    test "an uploaded theme is recognised" do
      assert ThemeOrigin.classify("upload://themes/deadbeef") == :uploaded
    end

    test "a bare digest names no agent, so it is not agent-supplied" do
      assert ThemeOrigin.classify(@local) == :local
      assert ThemeOrigin.agent(@local) == nil
    end

    test "the two metadata:// forms are not confused for one another" do
      # An agent id carries dots and an underscore; a digest is hex only.
      assert ThemeOrigin.classify(@observed) == :plex_agent
      assert ThemeOrigin.classify(@local) == :local
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

    test "nothing marked means nothing is being served" do
      # Observed on a live item: one theme listed, none marked, and the item's
      # own `theme` attribute empty. The old fallback to the first entry
      # reported a theme that was not playing.
      first = %{rating_key: @observed, selected: false}

      assert ThemeOrigin.selected([first, %{rating_key: "b", selected: false}]) == nil
    end

    test "no themes means nothing selected" do
      assert ThemeOrigin.selected([]) == nil
    end
  end

  describe "listed_not_selected?/1" do
    test "the state a freshly scanned theme.mp3 lands in" do
      assert ThemeOrigin.listed_not_selected?([%{rating_key: @local, selected: false}])
    end

    test "not when one is selected, and not when the list is empty" do
      refute ThemeOrigin.listed_not_selected?([%{rating_key: @local, selected: true}])
      refute ThemeOrigin.listed_not_selected?([])
    end
  end
end
