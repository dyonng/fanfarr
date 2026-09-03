defmodule FanfarrWeb.LogsLiveTest do
  @moduledoc "The log console, split out of the System page: filtering, secrets, clearing."
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Logger

  setup do
    Fanfarr.Log.Buffer.clear()
    Fanfarr.Diagnostics.Redactor.forget_all()
    on_exit(fn -> Fanfarr.Diagnostics.Redactor.forget_all() end)
    :ok
  end

  describe "the log console's shape" do
    test "an entry renders as one line, with nothing padding it", %{conn: conn} do
      Logger.error("something went wrong")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, _view, html} = live(conn, "/logs")

      # The element preserves whitespace so a stack trace keeps its shape, which
      # means the template's own newlines and indentation would show up as blank
      # lines between every entry -- which is exactly what happened.
      assert [row] =
               Regex.run(~r{<pre[^>]*>([^<]*something went wrong[^<]*)</pre>}, html,
                 capture: :all_but_first
               )

      refute row =~ "\n"
      assert row =~ ~r/^\d\d:\d\d:\d\d  error  something went wrong$/
    end

    test "the level is padded so messages line up", %{conn: conn} do
      Logger.error("short level")
      Logger.warning("long level")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, _view, html} = live(conn, "/logs")

      assert html =~ ~r/\d\d:\d\d:\d\d  error  short level/
      assert html =~ ~r/\d\d:\d\d:\d\d  warni  long level/
    end
  end

  describe "logs page" do
    test "shows captured log lines and filters them by level", %{conn: conn} do
      Logger.error("a distinctive error line")
      Logger.warning("a distinctive warning line")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")

      html = render_click(view, "refresh_logs", %{})
      assert html =~ "a distinctive error line"
      assert html =~ "a distinctive warning line"

      html = render_change(view, "set_log_level", %{"level" => "error"})
      assert html =~ "a distinctive error line"
      refute html =~ "a distinctive warning line"
    end

    test "a secret logged before the page loaded is not on the page", %{conn: conn} do
      Fanfarr.Settings.put_setting!("plex_token", "TOKEN-must-not-appear")
      Fanfarr.Diagnostics.Redactor.prime()
      Logger.error("requesting with X-Plex-Token=TOKEN-must-not-appear")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "refresh_logs", %{})

      refute html =~ "TOKEN-must-not-appear"
      assert html =~ "[redacted]"
    end

    test "clearing empties the log", %{conn: conn} do
      Logger.error("soon to be cleared")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "clear_logs", %{})

      refute html =~ "soon to be cleared"
    end
  end
end
