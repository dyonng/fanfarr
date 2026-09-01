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
