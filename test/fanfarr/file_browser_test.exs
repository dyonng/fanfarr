defmodule Fanfarr.FileBrowserTest do
  use ExUnit.Case, async: true

  alias Fanfarr.FileBrowser

  setup do
    root = Path.join(System.tmp_dir!(), "fanfarr-fb-#{:erlang.unique_integer([:positive])}")
    for d <- ["tv1", "tv2", ".hidden", "Movies"], do: File.mkdir_p!(Path.join(root, d))
    File.write!(Path.join(root, "a-file.txt"), "")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "lists directories only, without hidden ones, case-insensitively sorted", %{root: root} do
    assert {:ok, %{path: ^root, dirs: dirs}} = FileBrowser.list(root)
    assert Enum.map(dirs, & &1.name) == ["Movies", "tv1", "tv2"]
    assert Enum.all?(dirs, &String.starts_with?(&1.path, root))
  end

  test "knows its parent, and that / has none", %{root: root} do
    assert {:ok, %{parent: parent}} = FileBrowser.list(Path.join(root, "tv1"))
    assert parent == root
    assert {:ok, %{parent: nil}} = FileBrowser.list("/")
  end

  test "a missing or non-directory path is an error, not an empty listing", %{root: root} do
    assert {:error, :enoent} = FileBrowser.list(Path.join(root, "nope"))
    assert {:error, :enotdir} = FileBrowser.list(Path.join(root, "a-file.txt"))
  end

  test "an empty path means the root" do
    assert {:ok, %{path: "/"}} = FileBrowser.list("")
  end
end
