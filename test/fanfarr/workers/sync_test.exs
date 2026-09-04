defmodule Fanfarr.Workers.SyncTest do
  @moduledoc """
  The sync pipeline against a mocked Plex -- the point of the client behaviour.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    # Config.plex_config reads settings/env; give it something via settings.
    Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
    Fanfarr.Settings.put_setting!("plex_token", "test-token")
    :ok
  end

  defp section(over \\ %{}) do
    Map.merge(
      %{key: "1", title: "TV Shows", kind: :show, locations: ["/media/merged-storage/TV"]},
      over
    )
  end

  defp plex_item(over \\ %{}) do
    Map.merge(
      %{
        rating_key: "101",
        title: "One Piece",
        year: 1999,
        kind: :show,
        guid: "plex://show/abc",
        imdb_id: "tt0388629",
        tmdb_id: "37854",
        tvdb_id: nil,
        path: "/media/merged-storage/TV/One Piece (1999)",
        thumb: "/library/metadata/101/thumb/1",
        theme: nil,
        critic_score: 8.6,
        critic_score_source: "rottentomatoes",
        audience_score: 9.1,
        audience_score_source: "rottentomatoes",
        added_at: ~U[2024-01-01 00:00:00Z]
      },
      over
    )
  end

  test "library sync mirrors sections but does not enable them" do
    expect(Fanfarr.PlexClientMock, :sections, fn %{base_url: "http://plex.test:32400"} ->
      {:ok, [section(), section(%{key: "2", title: "Movies", kind: :movie})]}
    end)

    assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})

    sections = Fanfarr.Library.list_sections!()
    assert length(sections) == 2
    # Disabled by default: uploads are irreversible, libraries are opt-in.
    assert Enum.all?(sections, &(&1.enabled == false))
  end

  test "a sync asks ThemerrDB about whatever it just brought in" do
    # A sync is the only thing that introduces new titles, so it is the only
    # moment ThemerrDB has anything new to be asked about. Without this the
    # cache only warmed for items somebody opened by hand, and a bulk apply
    # skipped the rest for want of a lookup nobody knew to queue.
    expect(Fanfarr.PlexClientMock, :sections, fn _ -> {:ok, [section()]} end)

    assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})

    assert [job] =
             Oban.Job
             |> Fanfarr.Repo.all()
             |> Enum.filter(&(&1.worker =~ "RefreshThemerr"))

    # Scheduled, not immediate: the sections are still syncing, and a pass that
    # ran now would miss the items that prompted it.
    assert job.state == "scheduled"
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
  end

  test "sync does not re-enable a section the operator disabled" do
    expect(Fanfarr.PlexClientMock, :sections, 2, fn _ -> {:ok, [section()]} end)

    assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})

    [s] = Fanfarr.Library.list_sections!()
    s = Fanfarr.Library.set_section_enabled!(s, true)
    s = Fanfarr.Library.set_section_enabled!(s, false)

    assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})
    assert Fanfarr.Library.get_section!(s.id).enabled == false
  end

  test "an enabled section fans out and its items mirror in" do
    expect(Fanfarr.PlexClientMock, :sections, fn _ -> {:ok, [section()]} end)
    assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})

    [s] = Fanfarr.Library.list_sections!()
    Fanfarr.Library.set_section_enabled!(s, true)

    expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
      {:ok, [plex_item(), plex_item(%{rating_key: "102", title: "Fleabag", year: 2016})]}
    end)

    assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

    items = Fanfarr.Library.list_media_items!()
    assert Enum.map(items, & &1.title) |> Enum.sort() == ["Fleabag", "One Piece"]
    assert Enum.find(items, &(&1.title == "One Piece")).imdb_id == "tt0388629"
  end

  test "syncing twice updates rather than duplicates" do
    expect(Fanfarr.PlexClientMock, :sections, fn _ -> {:ok, [section()]} end)
    assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})
    [s] = Fanfarr.Library.list_sections!()

    expect(Fanfarr.PlexClientMock, :items, 2, fn _config, "1" ->
      {:ok, [plex_item()]}
    end)

    assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})
    assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

    assert length(Fanfarr.Library.list_media_items!()) == 1
  end

  describe "theme origin" do
    setup do
      expect(Fanfarr.PlexClientMock, :sections, fn _ -> {:ok, [section()]} end)
      assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})
      [s] = Fanfarr.Library.list_sections!()
      %{section: s}
    end

    defp themed(over \\ %{}) do
      Map.merge(
        %{
          rating_key: "metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908",
          key: "/library/metadata/101/file?url=...",
          selected: true,
          origin: :plex_agent,
          agent: "tv.plex.agents.series"
        },
        over
      )
    end

    test "an item with no theme costs no extra request", %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
        {:ok, [plex_item(%{theme: nil})]}
      end)

      # No :themes expectation is declared. verify_on_exit! turns any call
      # into a failure, which is the assertion: 2,168 un-themed items must not
      # each cost a round trip.
      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      assert item.plex_theme_origin == :none
      assert item.plex_theme_agent == nil
    end

    test "an agent-supplied theme is recorded as such", %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
        {:ok, [plex_item(%{theme: "/library/metadata/101/theme/1786914632"})]}
      end)

      expect(Fanfarr.PlexClientMock, :themes, fn _config, "101" -> {:ok, [themed()]} end)

      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      assert item.plex_theme_origin == :plex_agent
      assert item.plex_theme_agent == "tv.plex.agents.series"
      assert Ash.load!(item, :theme_status).theme_status == :plex_supplied
    end

    test "the selected theme wins when Plex offers several", %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
        {:ok, [plex_item(%{theme: "/library/metadata/101/theme/1"})]}
      end)

      expect(Fanfarr.PlexClientMock, :themes, fn _config, "101" ->
        {:ok,
         [
           themed(%{selected: false}),
           themed(%{
             rating_key: "upload://themes/deadbeef",
             selected: true,
             origin: :uploaded,
             agent: nil
           })
         ]}
      end)

      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      assert item.plex_theme_origin == :uploaded
    end

    test "a failed origin lookup degrades instead of failing the sync",
         %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
        {:ok, [plex_item(%{theme: "/library/metadata/101/theme/1"})]}
      end)

      expect(Fanfarr.PlexClientMock, :themes, fn _config, "101" ->
        {:error, :timeout}
      end)

      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      # Still present, still counted as having a theme -- just unattributed.
      assert item.plex_theme_origin == :unknown
      assert Ash.load!(item, :theme_status).theme_status == :plex_supplied
    end
  end

  describe "items the listing gives no path for" do
    setup do
      expect(Fanfarr.PlexClientMock, :sections, fn _ -> {:ok, [section()]} end)
      assert :ok = perform_job(Fanfarr.Workers.SyncLibrary, %{})
      [s] = Fanfarr.Library.list_sections!()
      %{section: s}
    end

    test "asks Plex per item, which is what :no_plex_path was", %{section: s} do
      # Every show synced with a nil path, so every apply was skipped with
      # :no_plex_path. The listing reported no Location for them.
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
        {:ok, [plex_item(%{path: nil})]}
      end)

      expect(Fanfarr.PlexClientMock, :item_path, fn _config, "101", :show ->
        {:ok, "/media/merged-storage/TV/One Piece (1999)"}
      end)

      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      assert item.plex_path == "/media/merged-storage/TV/One Piece (1999)"
    end

    test "an item the listing does describe costs no extra request", %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" -> {:ok, [plex_item()]} end)

      # No :item_path expectation; verify_on_exit! fails on any call.
      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      assert item.plex_path == "/media/merged-storage/TV/One Piece (1999)"
    end

    test "a path already stored is not looked up again, nor overwritten with nil",
         %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, 2, fn _config, "1" ->
        {:ok, [plex_item(%{path: nil})]}
      end)

      # Looked up once, on the first sync only.
      expect(Fanfarr.PlexClientMock, :item_path, 1, fn _config, "101", :show ->
        {:ok, "/media/merged-storage/TV/One Piece (1999)"}
      end)

      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})
      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})

      [item] = Fanfarr.Library.list_media_items!()
      assert item.plex_path == "/media/merged-storage/TV/One Piece (1999)"
    end

    test "an item Plex has no path for at all syncs without one", %{section: s} do
      expect(Fanfarr.PlexClientMock, :items, fn _config, "1" ->
        {:ok, [plex_item(%{path: nil})]}
      end)

      expect(Fanfarr.PlexClientMock, :item_path, fn _config, "101", :show ->
        {:error, :no_path_reported}
      end)

      # Still mirrored -- it just cannot have a theme written for it, which the
      # dashboard and the application log both say plainly.
      assert :ok = perform_job(Fanfarr.Workers.SyncSection, %{section_id: s.id})
      assert [%{plex_path: nil}] = Fanfarr.Library.list_media_items!()
    end
  end

  test "an unconfigured Plex cancels rather than retries" do
    Fanfarr.Settings.list_settings!() |> Enum.each(&Fanfarr.Settings.delete_setting!/1)
    System.delete_env("PLEX_URL")
    System.delete_env("PLEX_TOKEN")

    assert {:cancel, :plex_not_configured} = perform_job(Fanfarr.Workers.SyncLibrary, %{})
  end

  defp perform_job(worker, args) do
    worker.perform(%Oban.Job{args: stringify(args)})
  end

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()
end
