defmodule FanfarrWeb.PageControllerTest do
  use FanfarrWeb.ConnCase

  test "GET / renders the placeholder, themed", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Fanfarr"
    assert html =~ "Theme music for your Plex library"

    # The page must use the design tokens, not daisyUI names that resolve to
    # nothing. See FanfarrWeb.ThemeTokensTest for the general guard.
    assert html =~ "text-foreground"
    assert html =~ "bg-card"
    refute html =~ "base-content"
  end

  test "the page title is not still Phoenix's", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ "Phoenix Framework"
  end
end
