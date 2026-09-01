defmodule FaviconTest do
  @moduledoc """
  Static assets are only served if they appear in `static_paths/0`. A file that
  exists on disk but is not listed 404s, which for a favicon looks like the
  browser simply ignoring it.
  """
  use FanfarrWeb.ConnCase, async: true

  @icons ~w(favicon.svg favicon.ico apple-touch-icon.png)

  test "the icon files exist" do
    for file <- @icons do
      assert File.exists?("priv/static/#{file}"), "priv/static/#{file} is missing"
    end
  end

  test "each icon is declared in static_paths and is therefore served" do
    declared = FanfarrWeb.static_paths()

    for file <- @icons do
      assert file in declared,
             "#{file} is not in FanfarrWeb.static_paths/0, so Plug.Static will not serve it"
    end
  end

  test "the layout points at all three", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(href="/favicon.svg")
    assert html =~ ~s(href="/favicon.ico")
    assert html =~ ~s(href="/apple-touch-icon.png")
  end

  test "the ico really is a multi-size icon container" do
    <<_reserved::little-16, type::little-16, count::little-16, _rest::binary>> =
      File.read!("priv/static/favicon.ico")

    assert type == 1, "not an icon file"
    assert count == 3, "expected 16, 32 and 48px entries"
  end
end
