defmodule FanfarrWeb.LogsLiveTest do
  @moduledoc "The log console, split out of the System page: filtering, secrets, clearing."
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Logger

  setup do
    Fanfarr.Log.Buffer.clear()
    Fanfarr.Log.Store.clear()
    Fanfarr.Diagnostics.Redactor.forget_all()
    on_exit(fn -> Fanfarr.Diagnostics.Redactor.forget_all() end)
    :ok
  end

  # The page reads the persisted log, which is written on a timer. Draining
  # the buffer forwards what was logged; flushing the store writes it down.
  # Both are calls, so this is a settle rather than a sleep.
  defp settle do
    Fanfarr.Log.Buffer.entries(limit: 1)
    Fanfarr.Log.Store.flush()
  end

  describe "the log console's shape" do
    # Straight at the function rather than through the page: LiveViewTest
    # returns HTML that has been through Floki, which drops the
    # whitespace-only nodes between the column spans -- so the alignment this
    # is about is invisible from there even when it is correct in a browser.
    defp line(message, opts \\ []) do
      %{
        at: ~U[2026-09-04 02:14:07Z],
        level: Keyword.get(opts, :level, :error),
        message: message,
        where: Keyword.get(opts, :where, "Fanfarr.Thing.do_it/1")
      }
      |> FanfarrWeb.LogsLive.Index.log_line(Keyword.get(opts, :source, false))
      |> Phoenix.HTML.safe_to_string()
    end

    defp text(html), do: String.replace(html, ~r{<[^>]*>}, "")

    test "an entry renders as one line, with nothing padding it" do
      # The element preserves whitespace so a stack trace keeps its shape,
      # which means any newline or indentation the markup introduces shows up
      # as blank lines between every entry -- which is exactly what happened
      # once, and what the hand-built iodata exists to prevent.
      row = text(line("something went wrong"))

      refute row =~ "\n"
      assert row == "02:14:07  error  something went wrong"
    end

    test "the level is padded so messages line up" do
      assert text(line("short level", level: :error)) =~ "  error  short level"
      assert text(line("long level", level: :warning)) =~ "  warni  long level"
    end

    test "the source column keeps its own width when shown" do
      short = text(line("a message", source: true, where: "Foo.bar/1"))
      long = text(line("a message", source: true, where: "Fanfarr.Some.Long.Module.call/3"))

      # Whatever the module is called, the message starts in the same place.
      assert :binary.match(short, "a message") == :binary.match(long, "a message")
      assert short =~ "  error  Foo.bar/1  "
    end

    test "each kind of thing in a message gets its own colour" do
      html = line("wrote /tv1/Show/theme.mp3 in 12ms: :ok")

      assert html =~ ~s(<span class="text-sky-600 dark:text-sky-400">/tv1/Show/theme.mp3</span>)
      assert html =~ ~s(<span class="text-cyan-600 dark:text-cyan-400">12ms</span>)
      assert html =~ ~s(<span class="text-violet-600 dark:text-violet-400">:ok</span>)

      # And the line still reads exactly as it was logged.
      assert text(html) == "02:14:07  error  wrote /tv1/Show/theme.mp3 in 12ms: :ok"
    end

    test "ordinary words are left alone whatever they start with" do
      # Regex.split hands back the text between matches indistinguishably from
      # the matches, so a classifier that only looked at the first character
      # painted "GET /logs" as a module and ": " as an atom.
      html = line("GET /logs", level: :info)

      refute html =~ "text-blue-600"
      assert text(html) == "02:14:07  info   GET /logs"
    end

    test "markup in a log line is escaped rather than rendered" do
      # Log lines carry whatever a third party said, and this module builds
      # its markup by hand, which is what makes it worth asserting.
      html = line("a <script>alert('x')</script> line")

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end

    test "the whole line still reaches the page", %{conn: conn} do
      Logger.error("a distinctive line to find")
      settle()

      {:ok, _view, html} = live(conn, "/logs")

      assert html =~ "a distinctive line to find"
    end
  end

  describe "logs page" do
    test "shows captured log lines and filters them by level", %{conn: conn} do
      Logger.error("a distinctive error line")
      Logger.warning("a distinctive warning line")
      settle()

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
      settle()

      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "refresh_logs", %{})

      refute html =~ "TOKEN-must-not-appear"
      assert html =~ "[redacted]"
    end

    test "text search narrows to matching lines", %{conn: conn} do
      Logger.error("a haystack line")
      Logger.error("the needle is here")
      settle()

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
      settle()

      {:ok, view, _html} = live(conn, "/logs")

      assert render_change(view, "search", %{"query" => "LogsLiveTest"}) =~ "something happened"
    end

    test "no matches says how many lines the filters are hiding", %{conn: conn} do
      Logger.error("something entirely unrelated")
      settle()

      {:ok, view, _html} = live(conn, "/logs")

      html = render_change(view, "search", %{"query" => "zzzz-no-such-line"})
      assert html =~ "Nothing matches"
      refute html =~ "nothing captured yet"
    end

    test "the source column is off until asked for", %{conn: conn} do
      Logger.error("with a source")
      settle()

      {:ok, view, html} = live(conn, "/logs")
      refute html =~ "FanfarrWeb.LogsLiveTest"

      assert render_click(view, "toggle_source", %{}) =~ "FanfarrWeb.LogsLiveTest"
    end

    test "the status bar counts the whole buffer, not the filtered view", %{conn: conn} do
      Logger.error("an error line")
      Logger.warning("a warning line")
      settle()

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
      settle()

      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "clear_logs", %{})

      refute html =~ "soon to be cleared"
    end
  end
end
