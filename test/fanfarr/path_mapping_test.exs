defmodule Fanfarr.PathMappingTest do
  use ExUnit.Case, async: true

  alias Fanfarr.PathMapping

  doctest Fanfarr.PathMapping

  describe "parse/1" do
    test "returns nothing for empty configuration" do
      assert PathMapping.parse(nil) == []
      assert PathMapping.parse("") == []
      assert PathMapping.parse("   ") == []
    end

    test "accepts semicolons or newlines between pairs" do
      expected = [{"/data/anime", "/mnt/anime"}, {"/data", "/media"}]

      assert PathMapping.parse("/data:/media;/data/anime:/mnt/anime") == expected
      assert PathMapping.parse("/data:/media\n/data/anime:/mnt/anime") == expected
    end

    test "orders longest prefix first regardless of input order" do
      assert [{"/data/anime", _}, {"/data", _}] =
               PathMapping.parse("/data:/media; /data/anime:/mnt/anime")

      assert [{"/data/anime", _}, {"/data", _}] =
               PathMapping.parse("/data/anime:/mnt/anime; /data:/media")
    end

    test "treats trailing slashes as insignificant" do
      assert PathMapping.parse("/data/:/media/") == [{"/data", "/media"}]
    end

    test "discards malformed entries rather than failing the whole config" do
      assert PathMapping.parse("/data:/media; nonsense; :/media; /data2:") ==
               [{"/data", "/media"}]
    end
  end

  describe "to_local/2" do
    test "passes the path through when there are no mappings" do
      assert PathMapping.to_local("/data/tv/Show", []) == "/data/tv/Show"
    end

    test "rewrites a matching prefix" do
      mappings = PathMapping.parse("/data:/media")

      assert PathMapping.to_local("/data/tv/One Piece (1999)", mappings) ==
               "/media/tv/One Piece (1999)"
    end

    test "prefers the most specific mapping" do
      mappings = PathMapping.parse("/data:/media; /data/anime:/mnt/anime-ssd")

      assert PathMapping.to_local("/data/anime/One Piece", mappings) == "/mnt/anime-ssd/One Piece"
      assert PathMapping.to_local("/data/tv/Breaking Bad", mappings) == "/media/tv/Breaking Bad"
    end

    test "matches only on segment boundaries" do
      mappings = PathMapping.parse("/data/tv:/media/tv")

      # A sibling directory whose name merely starts with the prefix must not match.
      assert PathMapping.to_local("/data/tv-4k/Show", mappings) == "/data/tv-4k/Show"
      assert PathMapping.to_local("/data/tvshows", mappings) == "/data/tvshows"
    end

    test "translates the mapped root itself" do
      mappings = PathMapping.parse("/data:/media")

      assert PathMapping.to_local("/data", mappings) == "/media"
      assert PathMapping.to_local("/data/", mappings) == "/media"
    end

    test "leaves an unmatched path alone" do
      mappings = PathMapping.parse("/data:/media")

      assert PathMapping.to_local("/elsewhere/tv/Show", mappings) == "/elsewhere/tv/Show"
    end

    test "handles paths containing spaces and unicode" do
      mappings = PathMapping.parse("/data:/media")

      assert PathMapping.to_local("/data/tv/Kimi no Na wa. 君の名は。", mappings) ==
               "/media/tv/Kimi no Na wa. 君の名は。"
    end
  end

  describe "resolvable?/1" do
    test "is true for a real directory and false otherwise" do
      assert PathMapping.resolvable?(System.tmp_dir!())
      refute PathMapping.resolvable?("/definitely/not/a/real/path")
    end
  end
end
