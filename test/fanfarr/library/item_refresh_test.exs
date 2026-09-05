defmodule Fanfarr.Library.ItemRefreshTest do
  @moduledoc """
  Re-reading one item from Plex, which is what the Refresh button on its page
  does. The interesting cases are the two fields it refuses to blank.
  """
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  alias Fanfarr.Library
  alias Fanfarr.Library.ItemRefresh

  setup do
    Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
    Fanfarr.Settings.put_setting!("plex_token", "test-token")

    section =
      Library.sync_section_from_plex!(%{plex_key: "1", title: "Movies", kind: :movie})

    item =
      Library.sync_media_item_from_plex!(%{
        plex_rating_key: "500",
        section_id: section.id,
        title: "The Dark Night",
        year: 2008,
        kind: :movie,
        studio: "Old Studio",
        collections: ["Batman Collection"],
        plex_path: "/movies1/The Dark Night (2008)",
        critic_score: 5.0
      })

    %{section: section, item: item}
  end

  defp plex_item(over \\ %{}) do
    Map.merge(
      %{
        rating_key: "500",
        title: "The Dark Knight",
        year: 2008,
        kind: :movie,
        guid: "plex://movie/abc",
        imdb_id: "tt0468569",
        tmdb_id: "155",
        tvdb_id: nil,
        path: "/movies1/The Dark Knight (2008)",
        thumb: "/library/metadata/500/thumb/1",
        theme: nil,
        critic_score: 9.4,
        critic_score_source: "rottentomatoes",
        audience_score: 9.4,
        audience_score_source: "rottentomatoes",
        studio: "Warner Bros. Pictures",
        collections: ["Batman Collection", "DC Universe"],
        added_at: ~U[2024-01-01 00:00:00Z]
      },
      over
    )
  end

  test "it picks up a retitled, re-rated, re-studioed item", %{item: item} do
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" -> {:ok, plex_item()} end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)

    assert refreshed.title == "The Dark Knight"
    assert refreshed.studio == "Warner Bros. Pictures"
    assert refreshed.critic_score == 9.4
    assert refreshed.audience_score == 9.4
    assert refreshed.imdb_id == "tt0468569"
    assert refreshed.collections == ["Batman Collection", "DC Universe"]
    assert refreshed.plex_path == "/movies1/The Dark Knight (2008)"
  end

  test "it is the same row, not a replacement", %{item: item} do
    # Re-keying and history both depend on this: a refresh that created a
    # second row would strand the theme and the application log on the first.
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" -> {:ok, plex_item()} end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)

    assert refreshed.id == item.id
    assert length(Library.list_media_items!()) == 1
  end

  test "a response with no path keeps the one we had", %{item: item} do
    # The listing does not always report a path, and the section sync goes to
    # some trouble to recover it. Losing it here would break the next apply.
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" ->
      {:ok, plex_item(%{path: nil})}
    end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)

    assert refreshed.plex_path == "/movies1/The Dark Night (2008)"
  end

  test "a response with no collections keeps the ones we had", %{item: item} do
    # Agent-built collections are missing from the per-item tags on the
    # reference server, which is why the section sync reads them from the
    # collections endpoint. An empty answer here means "does not know".
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" ->
      {:ok, plex_item(%{collections: []})}
    end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)

    assert refreshed.collections == ["Batman Collection"]
  end

  test "the theme Plex serves is re-read when there is one", %{item: item} do
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" ->
      {:ok, plex_item(%{theme: "/library/metadata/500/theme/1"})}
    end)

    expect(Fanfarr.PlexClientMock, :themes, fn _config, "500" ->
      {:ok,
       [
         %{
           rating_key: "metadata://themes/tv.plex.agents.movie_abc",
           key: "/library/metadata/500/file",
           selected: true,
           origin: :plex_agent,
           agent: "tv.plex.agents.movie"
         }
       ]}
    end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)

    assert refreshed.plex_theme_origin == :plex_agent
    assert refreshed.plex_theme_agent == "tv.plex.agents.movie"
  end

  test "an item with no theme costs no second request", %{item: item} do
    # "No theme" is its own answer. No :themes expectation is declared, so
    # verify_on_exit! fails if one is made.
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" -> {:ok, plex_item()} end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)
    assert refreshed.plex_theme_origin == :none
  end

  test "a theme lookup that fails degrades rather than failing the refresh", %{item: item} do
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" ->
      {:ok, plex_item(%{theme: "/library/metadata/500/theme/1"})}
    end)

    expect(Fanfarr.PlexClientMock, :themes, fn _config, "500" -> {:error, :timeout} end)

    assert {:ok, refreshed} = ItemRefresh.refresh(item)

    assert refreshed.plex_theme_origin == :unknown
    assert refreshed.title == "The Dark Knight"
  end

  test "an item Plex no longer has is reported rather than guessed at", %{item: item} do
    expect(Fanfarr.PlexClientMock, :item, fn _config, "500" -> {:error, :not_found} end)

    assert {:error, :not_found} = ItemRefresh.refresh(item)

    # And nothing was written on the way to finding out.
    assert Library.get_media_item!(item.id).title == "The Dark Night"
  end

  test "an unconfigured Plex says so" do
    Fanfarr.Settings.list_settings!() |> Enum.each(&Fanfarr.Settings.delete_setting!/1)
    System.delete_env("PLEX_URL")
    System.delete_env("PLEX_TOKEN")

    [item] = Library.list_media_items!()

    assert {:error, :plex_not_configured} = ItemRefresh.refresh(item)
  end
end
