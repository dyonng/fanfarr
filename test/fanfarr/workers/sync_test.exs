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
