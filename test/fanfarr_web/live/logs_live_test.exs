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

    test "text search narrows to matching lines", %{conn: conn} do
      Logger.error("a haystack line")
      Logger.error("the needle is here")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")

      html = render_change(view, "search", %{"query" => "needle"})
      assert html =~ "the needle is here"
      refute html =~ "a haystack line"

      # And back again, so the filter is not one-way.
      html = render_change(view, "search", %{"query" => ""})
      assert html =~ "a haystack line"
    end

    test "search reaches the module that logged the line, not just its text", %{conn: conn} do
      # The message says nothing about where it came from; the metadata does.
      Logger.error("something happened")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")

      assert render_change(view, "search", %{"query" => "LogsLiveTest"}) =~ "something happened"
    end

    test "no matches says how many lines the filters are hiding", %{conn: conn} do
      Logger.error("something entirely unrelated")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")

      html = render_change(view, "search", %{"query" => "zzzz-no-such-line"})
      assert html =~ "Nothing matches"
      refute html =~ "nothing captured yet"
    end

    test "the source column is off until asked for", %{conn: conn} do
      Logger.error("with a source")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, html} = live(conn, "/logs")
      refute html =~ "FanfarrWeb.LogsLiveTest"

      assert render_click(view, "toggle_source", %{}) =~ "FanfarrWeb.LogsLiveTest"
    end

    test "the status bar counts the whole buffer, not the filtered view", %{conn: conn} do
      Logger.error("an error line")
      Logger.warning("a warning line")
      Fanfarr.Log.Buffer.entries(limit: 1)

      {:ok, view, _html} = live(conn, "/logs")

      # Filtering to one line must not make the other one stop existing: the
      # counts are there to decide what to filter to.
      html = render_change(view, "search", %{"query" => "an error line"})
      assert html =~ "1 error"
      assert html =~ "1 warning"
    end

    test "live tailing can be paused and resumed", %{conn: conn} do
      {:ok, view, html} = live(conn, "/logs")
      assert html =~ "Live"

      html = render_click(view, "toggle_live", %{})
      assert html =~ "Paused"
      # A paused console offers the manual refresh a live one does not need.
      assert html =~ "Refresh"

      assert render_click(view, "toggle_live", %{}) =~ "Live"
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
