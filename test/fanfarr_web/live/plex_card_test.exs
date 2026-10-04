defmodule FanfarrWeb.PlexCardTest do
  @moduledoc """
  The Plex card's test button: submit the form with `intent: "test"`.

  This was the one path in the dashboard with no test at all, and it is the one
  that talks to another machine. Submitting with `intent: "test"` saves nothing
  and probes the URL instead, so a typo can be tried before it is kept.

  The probe runs off the LiveView process through `start_async`, because a host
  that does not answer would otherwise hold the process past its own push
  timeout. The result therefore arrives an event later, and the render has to be
  waited for rather than assumed -- which is exactly the shape that made the
  notification test flake on CI.
  """
  use FanfarrWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user
  setup :verify_on_exit!

  @url "http://plex.test:32400"
  @saved "http://elsewhere.test:32400"

  defp submit_test(view) do
    view
    |> element("#plex-form")
    |> render_submit(%{"intent" => "test", "plex_url" => @url, "plex_token" => "tok"})
  end

  test "a server that answers is named, with its version", %{conn: conn} do
    expect(Fanfarr.PlexClientMock, :server_info, fn _config ->
      {:ok, %{name: "Living Room", version: "1.40.0"}}
    end)

    {:ok, view, _html} = live(conn, "/settings")
    submit_test(view)

    html = render_async(view, 5_000)
    assert html =~ "Connected to Living Room"
    assert html =~ "Plex 1.40.0"
  end

  test "a token Plex refuses says so instead of connecting", %{conn: conn} do
    expect(Fanfarr.PlexClientMock, :server_info, fn _config -> {:error, :unauthorized} end)

    {:ok, view, _html} = live(conn, "/settings")
    submit_test(view)

    assert render_async(view, 5_000) =~ "Plex rejected the token"
  end

  test "a host that does not answer is explained, not crashed on", %{conn: conn} do
    expect(Fanfarr.PlexClientMock, :server_info, fn _config ->
      {:error, %{reason: :econnrefused}}
    end)

    {:ok, view, _html} = live(conn, "/settings")
    submit_test(view)

    # The reason is translated rather than inspected: "connection refused (is
    # that the right port?)" is a sentence an operator can act on, and the raw
    # term is not.
    assert render_async(view, 5_000) =~ "connection refused"
  end

  test "testing does not save what was typed", %{conn: conn} do
    expect(Fanfarr.PlexClientMock, :server_info, fn _config ->
      {:ok, %{name: "Elsewhere", version: "1.40.0"}}
    end)

    Fanfarr.Settings.put_setting!("plex_url", @saved)
    {:ok, view, _html} = live(conn, "/settings")
    submit_test(view)

    render_async(view, 5_000)

    # The point of a separate test button: the URL just probed is the one in the
    # form, and what is configured stays where the operator left it. If this
    # ever fails, "Test" quietly became "Save".
    assert Fanfarr.Config.get("plex_url") == @saved
  end
end
