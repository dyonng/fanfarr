defmodule IconsTest do
  @moduledoc """
  Icons are CSS masks generated from SVG files on disk. A name with no matching
  file produces no class at all -- Tailwind does not warn -- so the icon simply
  vanishes. That is worth asserting rather than discovering in a screenshot.
  """
  use ExUnit.Case, async: true

  @icons_dir "deps/lucide/icons"

  defp referenced_icons do
    Path.wildcard("lib/**/*.{ex,heex}")
    |> Enum.flat_map(fn file ->
      ~r/class=(?:"([^"]*)"|\{([^}]*)\})|name="(lucide-[a-z0-9-]+)"/
      |> Regex.scan(File.read!(file))
      |> Enum.flat_map(fn m -> Enum.drop(m, 1) end)
      |> Enum.flat_map(&Regex.scan(~r/lucide-([a-z0-9-]+)/, &1, capture: :all_but_first))
      |> Enum.map(&{file, hd(&1)})
    end)
    |> Enum.uniq()
  end

  test "every referenced Lucide icon exists in the icon set" do
    missing =
      referenced_icons()
      |> Enum.reject(fn {_file, name} -> File.exists?(Path.join(@icons_dir, "#{name}.svg")) end)

    assert missing == [], """
    These icon names have no SVG in #{@icons_dir}, so they render as nothing:

    #{Enum.map_join(missing, "\n", fn {f, n} -> "  #{f}: lucide-#{n}" end)}

    Lucide renames icons between releases (help-circle is now
    circle-question-mark, for instance). Check https://lucide.dev, or grep
    deps/lucide/icons for the current name.
    """
  end

  test "no Heroicons remain" do
    offenders =
      Path.wildcard("lib/**/*.{ex,heex}")
      |> Enum.filter(&String.contains?(File.read!(&1), ~s(name="hero-)))

    assert offenders == [], """
    Heroicons references found, but the Heroicons dependency and its Tailwind
    plugin are gone -- these produce no CSS and render as empty spans:

    #{Enum.join(offenders, "\n")}
    """
  end

  test "the Lucide plugin scales the mask to the element" do
    plugin = File.read!("assets/vendor/lucide.js")

    # Lucide draws on a 24px grid. Without mask-size the artwork renders at its
    # intrinsic size and is clipped by any smaller box -- size-4, which most
    # call sites use.
    assert plugin =~ ~s("mask-size": "contain"),
           "without mask-size: contain, icons are clipped at any size below 24px"
  end
end
