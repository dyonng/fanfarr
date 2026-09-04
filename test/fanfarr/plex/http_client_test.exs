defmodule Fanfarr.Plex.HTTPClientTest do
  @moduledoc """
  The real client against responses captured verbatim from a live Plex server.

  These are not hand-written fixtures. They were copied out of a survey run
  against Plex Media Server 1.43.4 on the reference deployment, because the
  parser had never once executed against a real response and had already been
  wrong about a field (`provider`) that does not exist.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Plex.HTTPClient

  @config %{base_url: "http://plex.test:32400", token: "test-token"}

  # Verbatim from `/library/metadata/45870/themes` with Accept: application/json.
  # Note the JSON key is "Metadata" even though the XML element is <Track>, and
  # that `selected` is a real boolean rather than the XML's "1".
  @themes_json ~S|{"MediaContainer":{"size":1,"identifier":"com.plexapp.plugins.library","mediaTagPrefix":"/system/bundle/media/flags/","mediaTagVersion":1786914632,"Metadata":[{"key":"/library/metadata/45870/file?url=metadata%3A%2F%2Fthemes%2Ftv%2Eplex%2Eagents%2Eseries_b00837223037c5e21ab3a908018b4aed41791a2f","ratingKey":"metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f","thumb":"/library/metadata/45870/file?url=metadata%3A%2F%2Fthemes%2Ftv%2Eplex%2Eagents%2Eseries_b00837223037c5e21ab3a908018b4aed41791a2f","selected":true}]}}|

  defp stub(fun) do
    Req.Test.stub(Fanfarr.PlexReq, fun)
    :ok
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  describe "themes/2 against a captured response" do
    test "reads the agent-supplied theme out of the Metadata array" do
      stub(fn conn ->
        assert conn.request_path == "/library/metadata/45870/themes"
        assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["test-token"]
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
        json(conn, @themes_json)
      end)

      assert {:ok, [theme]} = HTTPClient.themes(@config, "45870")

      assert theme.origin == :plex_agent
      assert theme.agent == "tv.plex.agents.series"
      assert theme.selected == true

      assert theme.rating_key ==
               "metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f"
    end

    test "an item with no themes yields an empty list, not a crash" do
      stub(fn conn -> json(conn, ~S|{"MediaContainer":{"size":0}}|) end)

      assert {:ok, []} = HTTPClient.themes(@config, "1")
    end

    test "a bad token surfaces as :unauthorized" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, :unauthorized} = HTTPClient.themes(@config, "1")
    end
  end

  describe "server_info/1" do
    test "reads the server version, not the XML declaration's" do
      # The survey script got this wrong for two runs, reporting every server
      # as "1.0" because it matched <?xml version="1.0"?>. JSON has no such
      # trap, but the expected value is pinned so a regression is visible.
      body = ~S"""
      {"MediaContainer":{"friendlyName":"Serve The DY","version":"1.43.4.10903-e5521bd8c","platform":"Linux"}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, info} = HTTPClient.server_info(@config)
      assert info.name == "Serve The DY"
      assert info.version == "1.43.4.10903-e5521bd8c"
    end
  end

  describe "sections/1" do
    test "keeps show and movie libraries and drops music" do
      # Shapes taken from the reference server: Music is type "artist" and has
      # nothing to do with themes, and "Sets" is a movie library.
      body = ~S"""
      {"MediaContainer":{"Directory":[
        {"key":"1","type":"movie","title":"Movies","Location":[{"path":"/media/merged-storage/Movies"}]},
        {"key":"2","type":"show","title":"TV Shows","Location":[{"path":"/media/merged-storage/TV"}]},
        {"key":"5","type":"artist","title":"Music"},
        {"key":"3","type":"movie","title":"Sets","Location":[{"path":"/media/merged-storage/Sets"}]}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, sections} = HTTPClient.sections(@config)

      assert Enum.map(sections, & &1.title) == ["Movies", "TV Shows", "Sets"]
      refute Enum.any?(sections, &(&1.title == "Music"))
      assert Enum.find(sections, &(&1.key == "2")).kind == :show
      assert Enum.find(sections, &(&1.key == "1")).locations == ["/media/merged-storage/Movies"]
    end
  end

  describe "item_path/3" do
    test "reads a show's Location from its own metadata" do
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":"101","type":"show","title":"One Piece",
         "Location":[{"path":"/media/merged-storage/TV/One Piece (1999)"}]}
      ]}}
      """

      stub(fn conn ->
        assert conn.request_path == "/library/metadata/101"
        json(conn, body)
      end)

      assert {:ok, "/media/merged-storage/TV/One Piece (1999)"} =
               HTTPClient.item_path(@config, "101", :show)
    end

    test "falls back to an episode's directory, stepping over the season folder" do
      # The case that matters: Plex reports no Location for the show at all.
      meta = ~S"""
      {"MediaContainer":{"Metadata":[{"ratingKey":"101","type":"show","title":"One Piece"}]}}
      """

      leaves = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":"555","type":"episode",
         "Media":[{"Part":[{"file":"/tv2/One Piece (1999)/Season 01/S01E01.mkv"}]}]}
      ]}}
      """

      stub(fn conn ->
        case conn.request_path do
          "/library/metadata/101" -> json(conn, meta)
          "/library/metadata/101/allLeaves" -> json(conn, leaves)
        end
      end)

      assert {:ok, "/tv2/One Piece (1999)"} = HTTPClient.item_path(@config, "101", :show)
    end

    test "a flat show folder is not stepped over" do
      meta = ~S"""
      {"MediaContainer":{"Metadata":[{"ratingKey":"101","type":"show"}]}}
      """

      leaves = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":"555","Media":[{"Part":[{"file":"/tv2/Fleabag/ep1.mkv"}]}]}
      ]}}
      """

      stub(fn conn ->
        case conn.request_path do
          "/library/metadata/101" -> json(conn, meta)
          _ -> json(conn, leaves)
        end
      end)

      assert {:ok, "/tv2/Fleabag"} = HTTPClient.item_path(@config, "101", :show)
    end

    test "a movie with no path anywhere is an error, not a guess" do
      body = ~S"""
      {"MediaContainer":{"Metadata":[{"ratingKey":"9","type":"movie"}]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:error, :no_path_reported} = HTTPClient.item_path(@config, "9", :movie)
    end
  end

  describe "items/2" do
    test "the listing's theme attribute is captured but carries no origin" do
      # Verified: the listing reports theme="/library/metadata/45870/theme/1788156492".
      # That is a timestamped URL, not an origin -- which is exactly why sync
      # makes a second call to /themes for the items that have one.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":45870,"title":"OSHI NO KO","year":2023,"type":"show",
         "guid":"plex://show/abc","theme":"/library/metadata/45870/theme/1788156492",
         "addedAt":1704067200,
         "Location":[{"path":"/media/merged-storage/TV/Oshi no Ko (2023)"}],
         "Guid":[{"id":"imdb://tt15343280"},{"id":"tmdb://203737"},{"id":"tvdb://421378"}]}
      ]}}
      """

      stub(fn conn ->
        assert conn.query_string =~ "includeGuids=1"
        json(conn, body)
      end)

      assert {:ok, [item]} = HTTPClient.items(@config, "2")

      assert item.rating_key == "45870"
      assert item.theme == "/library/metadata/45870/theme/1788156492"
      assert Fanfarr.Plex.ThemeOrigin.classify(item.theme) == :unknown
      assert item.imdb_id == "tt15343280"
      assert item.tmdb_id == "203737"
      assert item.tvdb_id == "421378"
      assert item.path == "/media/merged-storage/TV/Oshi no Ko (2023)"
    end

    test "ratings and the service behind each are read from the listing" do
      # The field names are Plex's: `rating` and `audienceRating`, on a 0-10
      # scale whoever supplied them, with the service named only in the image
      # URL beside each. Unlike the captured responses above, this shape is
      # not taken off a live server -- so every one of these is treated as
      # optional, which the next two tests are about.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Heat","year":1995,"type":"movie","theme":null,
         "rating":8.7,"ratingImage":"rottentomatoes://image.rating.ripe",
         "audienceRating":9.4,"audienceRatingImage":"rottentomatoes://image.rating.upright"}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.critic_score == 8.7
      assert item.critic_score_source == "rottentomatoes"
      assert item.audience_score == 9.4
      assert item.audience_score_source == "rottentomatoes"
    end

    test "the operator's own star rating in Plex is not one of the scores" do
      # userRating is what one person thought, not how the thing was received.
      # An item rated in Plex but unrated by any service stays blank here.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Personal Favourite","type":"movie","theme":null,
         "userRating":10.0}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.critic_score == nil
      assert item.audience_score == nil
    end

    test "an item its agent has no opinion about syncs with no scores" do
      # The common case for anything obscure, and for whole libraries whose
      # agent supplies no ratings at all. It must not fail the sync.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Some Home Video","type":"movie","theme":null}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.critic_score == nil
      assert item.critic_score_source == nil
      assert item.audience_score == nil
      assert item.audience_score_source == nil
    end

    test "a rating with no image is kept, just with no name to put to it" do
      # The number is still worth having and still sorts; only the tooltip
      # loses anything.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Unbranded","type":"show","theme":null,"rating":7}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.critic_score == 7.0
      assert item.critic_score_source == nil
    end

    test "the studio and the collections an item is in are read from the listing" do
      # Both are for grouping a library. Note the studio here is the
      # distributor, not the production company -- which is exactly why the
      # collection is the better answer to "show me the Marvel films".
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Iron Man","year":2008,"type":"movie","theme":null,
         "studio":"Paramount Pictures",
         "Collection":[{"tag":"Marvel Cinematic Universe"},{"tag":"Phase One"}]}
      ]}}
      """

      stub(fn conn ->
        assert conn.query_string =~ "includeCollections=1"
        json(conn, body)
      end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.studio == "Paramount Pictures"
      assert item.collections == ["Marvel Cinematic Universe", "Phase One"]
    end

    test "an item in no collection, from an unnamed studio, syncs with neither" do
      # The common case for anything obscure, and for a whole library nobody
      # has organised. Neither may fail the sync.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Some Home Video","type":"movie","theme":null}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.studio == nil
      assert item.collections == []
    end

    test "a malformed collection entry is dropped rather than kept as nil" do
      # Belt and braces: this shape is not taken off a live server, so a tag
      # that is missing or blank must not reach the library as an unnamed
      # collection that then appears in the filter dropdown.
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"Odd One","type":"movie","theme":null,"studio":"   ",
         "Collection":[{"tag":"Real"},{"tag":"   "},{"nottag":"x"}]}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.studio == nil
      assert item.collections == ["Real"]
    end

    test "a movie's path comes from its file, since that is where theme.mp3 sits" do
      body = ~S"""
      {"MediaContainer":{"Metadata":[
        {"ratingKey":1,"title":"10 Cloverfield Lane","type":"movie","theme":null,
         "Media":[{"Part":[{"file":"/media/merged-storage/Movies/10 Cloverfield Lane (2016)/movie.mkv"}]}]}
      ]}}
      """

      stub(fn conn -> json(conn, body) end)

      assert {:ok, [item]} = HTTPClient.items(@config, "1")

      assert item.path == "/media/merged-storage/Movies/10 Cloverfield Lane (2016)"
      assert item.theme == nil
    end
  end
end
