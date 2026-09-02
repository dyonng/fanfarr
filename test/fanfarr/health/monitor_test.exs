defmodule Fanfarr.Health.MonitorTest do
  use Fanfarr.DataCase, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  alias Fanfarr.Health.Monitor

  test "a refresh takes a snapshot that latest/0 then returns" do
    # The application starts the monitor with auto: false in test, so nothing
    # has run until a refresh is asked for.
    stub(Fanfarr.ThemeDownloaderMock, :version, fn -> {:ok, "x"} end)
    Req.Test.set_req_test_to_shared(%{})
    Req.Test.stub(Fanfarr.PlexReq, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    snapshot = Monitor.refresh()

    assert %{results: results, at: %DateTime{}} = snapshot

    assert Enum.map(results, & &1.id) ==
             [
               :plex,
               :ytdlp,
               :ffmpeg,
               :root_folders,
               :local_assets,
               :paths,
               :themerrdb,
               :database
             ]

    assert Monitor.latest() == snapshot
  end
end
