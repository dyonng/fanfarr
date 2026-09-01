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

  test "the layout points at all three, undigested and cache-busted", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    for file <- @icons do
      assert html =~ ~s(href="/#{file}?v=),
             "#{file} should be linked at its plain path with a version query"
    end
  end

  test "the layout never links a digested icon path", %{conn: conn} do
    # The digested name is what 404'd in prod: it does not match Plug.Static's
    # :only list, and the failure is invisible in dev where nothing is digested.
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ ~r/href="\/favicon-[0-9a-f]{32}/
    refute html =~ ~r/href="\/apple-touch-icon-[0-9a-f]{32}/
  end

  test "the cache-busting token changes with the build" do
    assert Fanfarr.Version.asset_version() != ""

    assert Fanfarr.Version.asset_version() == Fanfarr.Version.build_ref() ||
             Fanfarr.Version.asset_version() == Fanfarr.Version.version()
  end

  test "the svg is drawable and parseable" do
    # SVG is XML, and XML forbids a double hyphen inside a comment. One in an
    # explanatory comment makes the whole file unparseable, and the browser
    # shows a broken image rather than reporting an error, so it fails silently
    # in exactly the way favicon bugs always do. This happened.
    svg = File.read!("priv/static/favicon.svg")

    assert svg =~ ~r/<(path|circle|rect|polygon)/,
           "the svg has no drawable elements"

    refute svg =~ ~r/<!--(?:(?!-->).)*--(?!>)/s,
           "a double hyphen inside an XML comment makes the svg unparseable"
  end

  test "the ico really is a multi-size icon container" do
    <<_reserved::little-16, type::little-16, count::little-16, _rest::binary>> =
      File.read!("priv/static/favicon.ico")

    assert type == 1, "not an icon file"
    assert count == 3, "expected 16, 32 and 48px entries"
  end

  describe "digested paths" do
    test "every bare file in static_paths has a matching prefix in only_matching" do
      # Digesting rewrites favicon.svg to favicon-<hash>.svg, which no longer
      # matches an exact Plug.Static :only entry. That 404'd every icon in prod
      # while working fine in dev, where nothing is digested. Directories are
      # exempt: digesting does not touch the directory segment.
      prefixes = FanfarrWeb.static_root_file_prefixes()

      bare_files = Enum.filter(FanfarrWeb.static_paths(), &String.contains?(&1, "."))

      assert bare_files != [], "expected static_paths to contain some root files"

      for file <- bare_files do
        assert Enum.any?(prefixes, &String.starts_with?(file, &1)),
               """
               #{file} is served from the root but no prefix in \
               static_root_file_prefixes/0 matches it, so its digested form \
               (#{Path.rootname(file)}-<hash>#{Path.extname(file)}) will 404 in prod.
               """
      end
    end

    test "the endpoint actually passes only_matching to Plug.Static" do
      # The list above is worthless if it is not wired in.
      source = File.read!("lib/fanfarr_web/endpoint.ex")

      assert source =~ "only_matching: FanfarrWeb.static_root_file_prefixes()"
    end
  end
end
