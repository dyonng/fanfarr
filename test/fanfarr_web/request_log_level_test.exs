defmodule FanfarrWeb.RequestLogLevelTest do
  use FanfarrWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias FanfarrWeb.RequestLogLevel

  describe "for_conn/1" do
    test "quiets the healthcheck path" do
      assert RequestLogLevel.for_conn(%Plug.Conn{request_path: "/health"}) == :debug
    end

    test "leaves every other path at the usual level" do
      for path <- ["/", "/library", "/settings", "/healthy", "/health/deep"] do
        assert RequestLogLevel.for_conn(%Plug.Conn{request_path: path}) == :info,
               "expected #{path} to stay at :info"
      end
    end
  end

  describe "wired into the endpoint" do
    setup do
      # The suite runs at :warning, which would hide the difference we are
      # testing. Put it back afterwards so the rest of the suite stays quiet.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "a healthcheck request logs nothing at :info", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/health") end)

      refute log =~ "/health"
    end

    test "an ordinary request still logs at :info", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/sign-in") end)

      assert log =~ "GET /sign-in"
    end
  end
end
