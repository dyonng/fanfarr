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
    @local_key "metadata://themes/46f33324b3bba73680ef38c5de0cd89664a55a1c"

    test "asks Plex to serve the theme, then reports what it actually serves" do
      # Plex answers the request before it has acted on it, so the state only
      # changes on a later read. Reading once would call this a failure.
      Agent.start_link(fn -> false end, name: :done?)

      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ ->
        if Agent.get(:done?, & &1),
          do: {:ok, %{"theme" => "/library/metadata/1/theme/9"}},
          else: {:ok, %{}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _, _ ->
        {:ok, [theme(@local_key, Agent.get(:done?, & &1))]}
      end)

      expect(Fanfarr.PlexClientMock, :select_theme, fn @config, "1", key ->
        assert key == @local_key
        Agent.update(:done?, fn _ -> true end)
        :ok
      end)

      assert {:ok, state} = ThemeCheck.select(@config, "1", @local_key)
      assert state.origin == :local
      assert state.url == "/library/metadata/1/theme/9"
    end

    test "a 200 that changed nothing is not reported as success" do
      # The endpoint is inferred from Plex's poster convention, so the
      # read-back is what decides, never the response to the request.
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, [theme(@local_key, false)]} end)
      expect(Fanfarr.PlexClientMock, :select_theme, fn _, _, _ -> :ok end)

      assert {:ok, state} = ThemeCheck.select(@config, "1", @local_key)
      assert state.url == nil
      assert state.origin == :none
      assert state.listed_not_selected
    end

    test "a refusal is passed through and no selection is claimed" do
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, [theme(@local_key, false)]} end)
      expect(Fanfarr.PlexClientMock, :select_theme, fn _, _, _ -> {:error, {:http, 404}} end)

      assert {:error, {:http, 404}} = ThemeCheck.select(@config, "1", @local_key)
    end
  end

  describe "locked_fields/1" do
    test "reads the fields Plex will not let its agents write" do
      meta = %{
        "Field" => [
          %{"name" => "title", "locked" => true},
          %{"name" => "summary", "locked" => false},
          %{"name" => "theme", "locked" => true}
        ]
      }

      assert ThemeCheck.locked_fields(meta) == ["title", "theme"]
    end

    test "XML's \"1\" counts as locked, the same as JSON's true" do
      assert ThemeCheck.locked_fields(%{"Field" => [%{"name" => "theme", "locked" => "1"}]}) ==
               ["theme"]
    end

    test "an item with nothing locked, and one that reports no fields at all" do
      assert ThemeCheck.locked_fields(%{"Field" => []}) == []
      assert ThemeCheck.locked_fields(%{}) == []
      assert ThemeCheck.locked_fields(nil) == []
    end
  end

  describe "the locked theme field" do
    test "a locked theme outranks every other reading" do
      # Nothing else can help while it holds: the agent has been told not to
      # write this field, so scanning and refreshing are both beside the point.
      state = %{
        origin: :none,
        listed_not_selected: true,
        locked_fields: ["theme"],
        rating_key: nil
      }

      assert {:warning, message} = ThemeCheck.verdict(state, %{local_theme_present: true})
      assert message =~ "locked in Plex"
      assert message =~ "Unlock it"
    end

    test "other locked fields do not change the reading" do
      state = %{
        origin: :none,
        listed_not_selected: true,
        locked_fields: ["title", "summary"],
        rating_key: nil
      }

      assert {:warning, message} = ThemeCheck.verdict(state, %{local_theme_present: true})
      assert message =~ "has not made it the item's theme"
    end
  end

  describe "upload/3" do
    test "hands Plex the bytes, then reports what it serves" do
      Agent.start_link(fn -> false end, name: :uploaded?)

      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ ->
        if Agent.get(:uploaded?, & &1),
          do: {:ok, %{"theme" => "/library/metadata/1/theme/9"}},
          else: {:ok, %{}}
      end)

      stub(Fanfarr.PlexClientMock, :themes, fn _, _ ->
        if Agent.get(:uploaded?, & &1),
          do: {:ok, [theme("upload://themes/deadbeef", true)]},
          else: {:ok, []}
      end)

      expect(Fanfarr.PlexClientMock, :upload_theme, fn @config, "1", {:file, path} ->
        assert path == "/tv/Show/theme.mp3"
        Agent.update(:uploaded?, fn _ -> true end)
        :ok
      end)

      assert {:ok, state} = ThemeCheck.upload(@config, "1", "/tv/Show/theme.mp3")
      assert state.origin == :uploaded
      assert state.url == "/library/metadata/1/theme/9"
    end

    test "a refused upload is passed through, not dressed up" do
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)

      expect(Fanfarr.PlexClientMock, :upload_theme, fn _, _, _ ->
        {:error, {:http, 500, "boom"}}
      end)

      assert {:error, {:http, 500, "boom"}} = ThemeCheck.upload(@config, "1", "/tv/S/theme.mp3")
    end

    test "an upload Plex accepts but does not act on is not called success" do
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)
      stub(Fanfarr.PlexClientMock, :themes, fn _, _ -> {:ok, []} end)
      expect(Fanfarr.PlexClientMock, :upload_theme, fn _, _, _ -> :ok end)

      assert {:ok, state} = ThemeCheck.upload(@config, "1", "/tv/S/theme.mp3")
      assert state.url == nil
      assert state.origin == :none
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
      expect(Fanfarr.PlexClientMock, :raw, 4, fn _config, path ->
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

          path == "/library/metadata/101/children" ->
            # As JSON actually comes back: seasons are <Directory> in XML but
            # "Metadata" in JSON. Reading only "Directory" reported every show
            # as having zero seasons.
            {:ok,
             %{
               "MediaContainer" => %{
                 "Metadata" => [%{"title" => "Season 1"}, %{"title" => "Season 2"}]
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

      # diagnose also asks for the item's locked fields, which come from
      # metadata rather than raw.
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ ->
        {:ok, %{"Field" => [%{"name" => "title", "locked" => true}]}}
      end)

      item = %{
        plex_rating_key: "101",
        kind: :show,
        plex_path: "/media/TV/Star City",
        local_theme_path: "/tv2/Star City/theme.mp3"
      }

      report = ThemeCheck.diagnose(@config, item, "2")

      assert report.section["agent"] == "tv.plex.agents.series"
      assert report.section["title"] == "TV"
      assert report.plex_locations == ["/media/TV/Star City"]
      assert report.wrote_to == "/tv2/Star City/theme.mp3"
      assert report.seasons == ["Season 1", "Season 2"]
      assert report.locked_fields == ["title"]

      # Listed, not interpreted: we do not claim to know which one governs
      # themes on this agent.
      assert [%{id: "enableLocalAssets", value: false}] =
               ThemeCheck.local_asset_prefs(report.prefs)
    end

    test "a section Plex will not describe does not take the whole report down" do
      stub(Fanfarr.PlexClientMock, :raw, fn _config, _path -> {:error, :unauthorized} end)
      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:error, :unauthorized} end)

      item = %{plex_rating_key: "101", kind: :show, plex_path: nil, local_theme_path: nil}
      report = ThemeCheck.diagnose(@config, item, "2")

      assert report.section == %{"error" => ":unauthorized"}
      assert report.prefs == []
      assert report.plex_locations == []
      assert report.seasons == nil

      # nil, not [] -- "we could not ask" is not "nothing is locked".
      assert report.locked_fields == nil
    end

    test "seasons are read from the XML element name too" do
      stub(Fanfarr.PlexClientMock, :raw, fn _config, path ->
        if path =~ "children" do
          {:ok, %{"MediaContainer" => %{"Directory" => [%{"title" => "Season 1"}]}}}
        else
          {:ok, %{}}
        end
      end)

      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)

      item = %{plex_rating_key: "7", kind: :show, plex_path: "/t/S", local_theme_path: nil}
      assert ThemeCheck.diagnose(@config, item, "2").seasons == ["Season 1"]
    end

    test "a movie is not asked for seasons" do
      stub(Fanfarr.PlexClientMock, :raw, fn _config, path ->
        refute path =~ "children"
        {:ok, %{}}
      end)

      stub(Fanfarr.PlexClientMock, :metadata, fn _, _ -> {:ok, %{}} end)

      item = %{plex_rating_key: "9", kind: :movie, plex_path: "/m/Heat", local_theme_path: nil}
      assert ThemeCheck.diagnose(@config, item, "1").seasons == nil
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
