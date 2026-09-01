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
