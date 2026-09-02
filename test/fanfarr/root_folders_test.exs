defmodule Fanfarr.Library.RootFoldersTest do
  use ExUnit.Case, async: true

  alias Fanfarr.Library.RootFolders

  # Mirrors the reference deployment: several drives, each holding part of one
  # library, presented through a pool that Plex reads from.
  setup do
    base = Path.join(System.tmp_dir!(), "fanfarr-roots-#{System.unique_integer([:positive])}")

    drives = ~w(the-biggest-one red-10 thiccer)
    roots = Enum.map(drives, &Path.join([base, &1, "TV"]))
    Enum.each(roots, &File.mkdir_p!/1)

    pool = Path.join([base, "merged-storage", "TV"])
    File.mkdir_p!(pool)

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, roots: roots, pool: pool}
  end

  defp show(root, name, files \\ []) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    Enum.each(files, &File.write!(Path.join(dir, &1), ""))
    dir
  end

  describe "with no root folders configured" do
    test "uses the reported path as given", %{pool: pool} do
      dir = Path.join(pool, "One Piece (1999)")
      assert {:ok, ^dir, :reported} = RootFolders.resolve(dir, [])
    end

    test "strips a trailing slash", %{pool: pool} do
      dir = Path.join(pool, "Fleabag (2016)")
      assert {:ok, resolved, :reported} = RootFolders.resolve(dir <> "/", [])
      assert resolved == dir
    end
  end

  describe "a title grouped inside a collection folder" do
    # The reference library groups sequels:
    #   .../MorePlex/Movies/Harry Potter/Harry Potter and the Chamber of Secrets (2002) (...)
    # Matching only the film's own directory name against each root found
    # nothing, and the item reported :no_matching_root.
    test "resolves through the grouping folder", %{roots: roots, pool: pool} do
      root = Enum.at(roots, 0)
      expected = show(Path.join(root, "Harry Potter"), "Chamber of Secrets (2002)")
      reported = Path.join([pool, "Harry Potter", "Chamber of Secrets (2002)"])

      assert {:ok, ^expected, :root_folder} = RootFolders.resolve(reported, roots)
    end

    test "the shortest tail that resolves is the one used", %{roots: roots, pool: pool} do
      # The same film name exists directly under one root and inside a grouping
      # folder under another. Shortest-first is the rule, so the direct one
      # wins -- it is also what resolved before deeper tails were tried, which
      # is why the rule is this way round: an item that resolves today must
      # keep resolving to the same place.
      shallow = show(Enum.at(roots, 0), "Goblet (2005)")
      show(Path.join(Enum.at(roots, 1), "Harry Potter"), "Goblet (2005)")

      reported = Path.join([pool, "Harry Potter", "Goblet (2005)"])
      assert {:ok, ^shallow, :root_folder} = RootFolders.resolve(reported, roots)
    end

    test "grouping is still reported as not found when nothing holds it", %{
      roots: roots,
      pool: pool
    } do
      reported = Path.join([pool, "Harry Potter", "A Film Nobody Has (1999)"])
      assert {:error, :not_found} = RootFolders.resolve(reported, roots)
    end

    test "a grouped title on two drives is still disambiguated", %{roots: roots, pool: pool} do
      busy = show(Path.join(Enum.at(roots, 0), "Harry Potter"), "Azkaban (2004)", ~w(a.mkv b.srt))
      show(Path.join(Enum.at(roots, 1), "Harry Potter"), "Azkaban (2004)")

      reported = Path.join([pool, "Harry Potter", "Azkaban (2004)"])
      assert {:ok, ^busy, :root_folder} = RootFolders.resolve(reported, roots)
    end
  end

  describe "resolving a pool path to a real drive" do
    test "finds the single drive holding the show", %{roots: roots, pool: pool} do
      expected = show(Enum.at(roots, 1), "Breaking Bad (2008)", ["s01e01.mkv"])

      assert {:ok, ^expected, :root_folder} =
               RootFolders.resolve(Path.join(pool, "Breaking Bad (2008)"), roots)
    end

    test "reports not found when no drive holds it", %{roots: roots, pool: pool} do
      assert {:error, :not_found} =
               RootFolders.resolve(Path.join(pool, "Nonexistent Show"), roots)
    end

    test "leaves a path that is already under a root alone", %{roots: roots} do
      dir = show(hd(roots), "Fleabag (2016)")
      assert {:ok, ^dir, :reported} = RootFolders.resolve(dir, roots)
    end
  end

  describe "a show split across drives" do
    test "prefers the drive that already has a theme", %{roots: roots, pool: pool} do
      show(Enum.at(roots, 0), "One Piece (1999)", ["s01e01.mkv", "s01e02.mkv", "s01e03.mkv"])
      with_theme = show(Enum.at(roots, 1), "One Piece (1999)", ["s02e01.mkv", "theme.mp3"])

      # Updating must land on the existing theme rather than creating a second
      # one on another disk, even though this drive holds fewer files.
      assert {:ok, ^with_theme, :root_folder} =
               RootFolders.resolve(Path.join(pool, "One Piece (1999)"), roots)
    end

    test "otherwise prefers the drive holding most of the show", %{roots: roots, pool: pool} do
      bulk = show(Enum.at(roots, 0), "Dickinson", ["a.mkv", "b.mkv", "c.mkv"])
      show(Enum.at(roots, 2), "Dickinson", ["d.mkv"])

      assert {:ok, ^bulk, :root_folder} =
               RootFolders.resolve(Path.join(pool, "Dickinson"), roots)
    end

    test "reports ambiguity rather than choosing silently on a tie", %{roots: roots, pool: pool} do
      show(Enum.at(roots, 0), "SuperKitties", ["a.mkv"])
      show(Enum.at(roots, 1), "SuperKitties", ["b.mkv"])

      assert {:ok, chosen, :ambiguous} =
               RootFolders.resolve(Path.join(pool, "SuperKitties"), roots)

      assert Path.basename(chosen) == "SuperKitties"
    end

    test "lists every drive holding the show", %{roots: roots, pool: pool} do
      show(Enum.at(roots, 0), "Severance", ["a.mkv"])
      show(Enum.at(roots, 2), "Severance", ["b.mkv"])

      candidates = RootFolders.candidates(Path.join(pool, "Severance"), roots)

      assert length(candidates) == 2
      assert Enum.all?(candidates, &(Path.basename(&1) == "Severance"))
    end
  end

  describe "names that need care" do
    test "handles spaces, punctuation and unicode", %{roots: roots, pool: pool} do
      expected = show(hd(roots), "Kimi no Na wa. 君の名は。", ["a.mkv"])

      assert {:ok, ^expected, :root_folder} =
               RootFolders.resolve(Path.join(pool, "Kimi no Na wa. 君の名は。"), roots)
    end

    test "does not confuse a show with one whose name is a prefix", %{roots: roots, pool: pool} do
      show(hd(roots), "Sherlock")
      expected = show(Enum.at(roots, 1), "Sherlock Holmes (2009)", ["a.mkv"])

      assert {:ok, ^expected, :root_folder} =
               RootFolders.resolve(Path.join(pool, "Sherlock Holmes (2009)"), roots)
    end
  end
end
