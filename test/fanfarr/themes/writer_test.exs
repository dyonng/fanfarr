defmodule Fanfarr.Themes.WriterTest do
  @moduledoc """
  The writer, including the cross-filesystem case that the reference
  deployment hits as a matter of course rather than as an edge case.
  """
  use ExUnit.Case, async: true

  alias Fanfarr.Themes.Writer

  setup do
    root = Path.join(System.tmp_dir!(), "fanfarr-writer-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "src"))
    File.mkdir_p!(Path.join(root, "dest"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, src: Path.join(root, "src"), dest: Path.join(root, "dest")}
  end

  defp source(dir, contents \\ "audio-bytes") do
    path = Path.join(dir, "theme-#{:erlang.unique_integer([:positive])}.mp3")
    File.write!(path, contents)
    path
  end

  test "places the file and consumes the source", ctx do
    src = source(ctx.src)
    dst = Path.join(ctx.dest, "theme.mp3")

    assert :ok = Writer.place(src, dst)
    assert File.read!(dst) == "audio-bytes"
    refute File.exists?(src), "the source should be consumed, not duplicated"
  end

  test "replaces an existing theme", ctx do
    dst = Path.join(ctx.dest, "theme.mp3")
    File.write!(dst, "the-old-one")

    assert :ok = Writer.place(source(ctx.src, "the-new-one"), dst)
    assert File.read!(dst) == "the-new-one"
  end

  test "leaves no temporary files behind on success", ctx do
    dst = Path.join(ctx.dest, "theme.mp3")
    assert :ok = Writer.place(source(ctx.src), dst)

    assert File.ls!(ctx.dest) == ["theme.mp3"]
  end

  test "leaves nothing behind when the destination directory does not exist", ctx do
    src = source(ctx.src)
    dst = Path.join([ctx.root, "nope", "theme.mp3"])

    assert {:error, :enoent} = Writer.place(src, dst)
    # The download is still there to retry with, rather than silently gone.
    assert File.exists?(src)
    refute File.exists?(dst)
  end

  test "a missing source is an error, not a zero-byte destination", ctx do
    dst = Path.join(ctx.dest, "theme.mp3")

    assert {:error, :enoent} = Writer.place(Path.join(ctx.src, "absent.mp3"), dst)
    refute File.exists?(dst)
    assert File.ls!(ctx.dest) == []
  end

  describe "across a filesystem boundary" do
    setup ctx do
      # tmpfs mounted at a second path gives a genuine EXDEV, which is the
      # whole point: mergerfs with category.create=mfs returns it routinely,
      # and a test that only ever renames within one filesystem proves
      # nothing about the deployment this code was written for.
      other = Path.join(ctx.root, "otherfs")
      File.mkdir_p!(other)

      case System.cmd("mount", ["-t", "tmpfs", "-o", "size=8m", "tmpfs", other],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          on_exit(fn -> System.cmd("umount", [other], stderr_to_stdout: true) end)
          %{other: other}

        {out, _} ->
          # Unprivileged CI cannot mount. Say so rather than passing quietly.
          {:skip, "cannot mount tmpfs for a real EXDEV test: #{String.trim(out)}"}
      end
    end

    test "falls back to copy when rename crosses filesystems", ctx do
      src = Path.join(ctx.other, "downloaded.mp3")
      File.write!(src, "cross-device-bytes")
      dst = Path.join(ctx.dest, "theme.mp3")

      # Prove the premise: a direct rename really does fail here.
      assert {:error, :exdev} = File.rename(src, Path.join(ctx.dest, "probe.mp3"))

      assert :ok = Writer.place(src, dst)
      assert File.read!(dst) == "cross-device-bytes"
      refute File.exists?(src)
      assert File.ls!(ctx.dest) == ["theme.mp3"]
    end
  end
end
