defmodule Fanfarr.Plex.ThemeCheckTest do
  use ExUnit.Case, async: true

  import Mox

  alias Fanfarr.Plex.ThemeCheck

  setup :verify_on_exit!

  @config %{url: "http://plex.test:32400", token: "t"}
  @agent_key "metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f"

  defp theme(rating_key, selected \\ true) do
    %{
      rating_key: rating_key,
      key: "/library/metadata/1/file?url=#{rating_key}",
      selected: selected,
      origin: Fanfarr.Plex.ThemeOrigin.classify(rating_key),
      agent: Fanfarr.Plex.ThemeOrigin.agent(rating_key)
    }
  end

  describe "read/2" do
    test "reports the selected theme's origin and the metadata theme url" do
      expect(Fanfarr.PlexClientMock, :metadata, fn @config, "1" ->
        {:ok, %{"theme" => "/library/metadata/1/theme/1788156492"}}
      end)

      expect(Fanfarr.PlexClientMock, :themes, fn @config, "1" ->
        {:ok, [theme(@agent_key)]}
      end)

      assert {:ok, state} = ThemeCheck.read(@config, "1")
      assert state.url == "/library/metadata/1/theme/1788156492"
      assert state.origin == :plex_agent
      assert state.agent == "tv.plex.agents.series"
      assert state.rating_key == @agent_key
    end

    test "an item with no theme reports :none rather than guessing" do
      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      expect(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)

      assert {:ok, %{url: nil, origin: :none, agent: nil, themes: []}} =
               ThemeCheck.read(@config, "1")
    end

    test "an empty theme string is not a theme" do
      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{"theme" => ""}} end)
      expect(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)

      assert {:ok, %{url: nil}} = ThemeCheck.read(@config, "1")
    end

    test "a read error is passed through" do
      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:error, :timeout} end)

      assert {:error, :timeout} = ThemeCheck.read(@config, "1")
    end
  end

  describe "refresh_and_reread/3" do
    test "the folder is scanned before the item is refreshed" do
      # The whole point: Plex's scanner has to walk the folder or the metadata
      # agents re-run against a listing that does not mention our theme.mp3.
      test_pid = self()

      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)

      expect(Fanfarr.PlexClientMock, :scan_directory, fn @config, "2", "/media/TV/Star City" ->
        send(test_pid, :scanned)
        :ok
      end)

      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _, "1" ->
        send(test_pid, :refreshed)
        :ok
      end)

      assert {:ok, _before, current} =
               ThemeCheck.refresh_and_reread(@config, "1", {"2", "/media/TV/Star City"})

      assert current.scanned == :ok
      assert_received :scanned
      assert_received :refreshed
    end

    test "a refused scan does not withhold the refresh, and is reported" do
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)
      expect(Fanfarr.PlexClientMock, :scan_directory, fn _, _, _ -> {:error, {:http, 404}} end)
      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _, _ -> :ok end)

      assert {:ok, _before, current} =
               ThemeCheck.refresh_and_reread(@config, "1", {"2", "/media/TV/Star City"})

      assert current.scanned == {:error, {:http, 404}}
    end

    test "with no known Plex path there is nothing to scan" do
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)
      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _, _ -> :ok end)

      assert {:ok, _before, current} = ThemeCheck.refresh_and_reread(@config, "1", nil)
      assert current.scanned == :not_attempted
    end

    test "stops polling as soon as the state changes" do
      # before
      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      expect(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)

      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _, "1" -> :ok end)

      # first poll: now has a theme, so the second poll never runs
      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ ->
        {:ok, %{"theme" => "/library/metadata/1/theme/9"}}
      end)

      expect(Fanfarr.PlexClientMock, :themes, fn _, _ ->
        {:ok, [theme("upload://themes/deadbeef")]}
      end)

      assert {:ok, before, current} = ThemeCheck.refresh_and_reread(@config, "1")
      assert before.origin == :none
      assert current.origin == :uploaded
      assert ThemeCheck.changed?(before, current)
    end

    test "an unchanged state is still reported after the last poll" do
      # before, then two polls, all identical
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)
      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _, "1" -> :ok end)

      assert {:ok, before, current} = ThemeCheck.refresh_and_reread(@config, "1")
      assert current.origin == :none
      refute ThemeCheck.changed?(before, current)
    end

    test "a refused refresh is not dressed up as a result" do
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)
      expect(Fanfarr.PlexClientMock, :refresh_metadata, fn _, _ -> {:error, {:http, 401}} end)

      assert {:error, {:http, 401}} = ThemeCheck.refresh_and_reread(@config, "1")
    end
  end

  describe "select/3" do
    test "asks Plex to serve the theme, then reports what it actually serves" do
      expect(Fanfarr.PlexClientMock, :select_theme, fn @config, "1", key ->
        assert key == @agent_key
        :ok
      end)

      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ ->
        {:ok, %{"theme" => "/library/metadata/1/theme/9"}}
      end)

      expect(Fanfarr.PlexClientMock, :themes, fn _, _ ->
        {:ok, [theme("metadata://themes/46f33324b3bba73680ef38c5de0cd89664a55a1c")]}
      end)

      assert {:ok, state} = ThemeCheck.select(@config, "1", @agent_key)
      assert state.origin == :local
      assert state.url == "/library/metadata/1/theme/9"
    end

    test "a 200 that changed nothing is not reported as success" do
      # The endpoint is inferred from Plex's poster convention, so the
      # read-back is what decides, never the response to the request.
      expect(Fanfarr.PlexClientMock, :select_theme, fn _, _, _ -> :ok end)
      expect(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)

      expect(Fanfarr.PlexClientMock, :themes, fn _, _ ->
        {:ok, [theme(@agent_key, false)]}
      end)

      assert {:ok, state} = ThemeCheck.select(@config, "1", @agent_key)
      assert state.url == nil
      assert state.origin == :none
      assert state.listed_not_selected
    end

    test "a refusal is passed through and nothing is read back" do
      expect(Fanfarr.PlexClientMock, :select_theme, fn _, _, _ -> {:error, {:http, 404}} end)

      assert {:error, {:http, 404}} = ThemeCheck.select(@config, "1", @agent_key)
    end
  end

  describe "verdict/2" do
    test "a local file plus no theme after a successful scan is the actionable case" do
      item = %{local_theme_present: true, local_theme_path: "/tv/Show/theme.mp3"}

      assert {:warning, message} = ThemeCheck.verdict(%{origin: :none, scanned: :ok}, item)
      assert message =~ "accepted a scan of the folder"
      assert message =~ "may not be reading local assets"
    end

    test "a scan that never ran is named as the reason, not the library settings" do
      item = %{local_theme_present: true, local_theme_path: "/tv/Show/theme.mp3"}

      assert {:warning, message} =
               ThemeCheck.verdict(%{origin: :none, scanned: :not_attempted}, item)

      assert message =~ "we do not know where Plex thinks this item lives"
    end

    test "a refused scan is named as the reason" do
      item = %{local_theme_present: true, local_theme_path: "/tv/Show/theme.mp3"}

      assert {:warning, message} =
               ThemeCheck.verdict(%{origin: :none, scanned: {:error, {:http, 404}}}, item)

      assert message =~ "refused to scan"
    end

    test "a local file losing to the agent's theme names the agent" do
      item = %{local_theme_present: true, local_theme_path: "/tv/Show/theme.mp3"}
      state = %{origin: :plex_agent, agent: "tv.plex.agents.series", rating_key: @agent_key}

      assert {:warning, message} = ThemeCheck.verdict(state, item)
      assert message =~ "tv.plex.agents.series"
    end

    test "no local file and no theme is information, not a warning" do
      assert {:info, _} = ThemeCheck.verdict(%{origin: :none}, %{local_theme_present: false})
    end

    test "an unattributed theme beside a local file reads as success" do
      item = %{local_theme_present: true, local_theme_path: "/tv/Show/theme.mp3"}
      state = %{origin: :unknown, rating_key: "something://else"}

      assert {:ok, message} = ThemeCheck.verdict(state, item)
      assert message =~ "something://else"
    end
  end

  describe "diagnose/3" do
    test "reports the library's agent, both folders, and the settings verbatim" do
      expect(Fanfarr.PlexClientMock, :raw, 3, fn _config, path ->
        cond do
          path == "/library/sections" ->
            {:ok,
             %{
               "MediaContainer" => %{
                 "Directory" => [
                   %{"key" => "1", "title" => "Other"},
                   %{
                     "key" => "2",
                     "title" => "TV",
                     "agent" => "tv.plex.agents.series",
                     "scanner" => "Plex TV Series"
                   }
                 ]
               }
             }}

          path == "/library/sections/2/prefs" ->
            {:ok,
             %{
               "MediaContainer" => %{
                 "Setting" => [
                   %{
                     "id" => "enableLocalAssets",
                     "label" => "Use local assets",
                     "value" => false
                   },
                   %{"id" => "collectionMode", "label" => "Collections", "value" => 0}
                 ]
               }
             }}

          path == "/library/metadata/101" ->
            {:ok,
             %{
               "MediaContainer" => %{
                 "Metadata" => [%{"Location" => [%{"path" => "/media/TV/Star City"}]}]
               }
             }}
        end
      end)

      item = %{
        plex_rating_key: "101",
        plex_path: "/media/TV/Star City",
        local_theme_path: "/tv2/Star City/theme.mp3"
      }

      report = ThemeCheck.diagnose(@config, item, "2")

      assert report.section["agent"] == "tv.plex.agents.series"
      assert report.section["title"] == "TV"
      assert report.plex_locations == ["/media/TV/Star City"]
      assert report.wrote_to == "/tv2/Star City/theme.mp3"

      # Listed, not interpreted: we do not claim to know which one governs
      # themes on this agent.
      assert [%{id: "enableLocalAssets", value: false}] =
               ThemeCheck.local_asset_prefs(report.prefs)
    end

    test "a section Plex will not describe does not take the whole report down" do
      stub(Fanfarr.PlexClientMock, :raw, fn _config, _path -> {:error, :unauthorized} end)

      item = %{plex_rating_key: "101", plex_path: nil, local_theme_path: nil}
      report = ThemeCheck.diagnose(@config, item, "2")

      assert report.section == %{"error" => ":unauthorized"}
      assert report.prefs == []
      assert report.plex_locations == []
    end
  end

  describe "local_assets_off?/1" do
    # Copied from a live server: the library that would not pick up a theme.mp3
    # sitting in exactly the right folder.
    @observed_prefs [
      %{id: "prefLocalArtwork", label: "Prefer artwork based on library language", value: true},
      %{id: "enableLocalAssets", label: "Use local assets", value: false},
      %{id: "preferLocalMetadata", label: "Prefer local metadata", value: false}
    ]

    test "the observed library reads as off" do
      assert ThemeCheck.local_assets_off?(@observed_prefs) == true
    end

    test "on is on" do
      prefs = [%{id: "enableLocalAssets", label: "Use local assets", value: true}]
      assert ThemeCheck.local_assets_off?(prefs) == false
    end

    test "Plex's several ways of spelling false all count" do
      for value <- [false, "false", 0, "0"] do
        prefs = [%{id: "enableLocalAssets", label: "Use local assets", value: value}]
        assert ThemeCheck.local_assets_off?(prefs) == true
      end
    end

    test "matched on the label too, since the id differs across agent generations" do
      prefs = [%{id: "someOtherId", label: "Use local assets", value: false}]
      assert ThemeCheck.local_assets_off?(prefs) == true
    end

    test "a library that did not report the setting is nil, not off" do
      assert ThemeCheck.local_assets_off?([]) == nil

      assert ThemeCheck.local_assets_off?([
               %{id: "collectionMode", label: "Collections", value: 0}
             ]) ==
               nil
    end

    test "'Prefer local metadata' is a different setting and is not mistaken for it" do
      prefs = [%{id: "preferLocalMetadata", label: "Prefer local metadata", value: false}]
      assert ThemeCheck.local_assets_off?(prefs) == nil
    end
  end

  describe "changed?/2" do
    test "a failed pre-refresh read is never reported as a change" do
      refute ThemeCheck.changed?(nil, %{origin: :none})
    end
  end
end
