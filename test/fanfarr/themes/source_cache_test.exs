defmodule Fanfarr.Themes.SourceCacheTest do
  @moduledoc """
  The cache that makes trimming not re-download on every drag.
  """
  use ExUnit.Case, async: false

  alias Fanfarr.Themes.SourceCache

  @url "https://www.youtube.com/watch?v=abc12345678"
  @other "https://www.youtube.com/watch?v=zzz99999999"

  setup do
    dir = Path.join(System.tmp_dir!(), "fanfarr-cache-#{System.unique_integer([:positive])}")
    Application.put_env(:fanfarr, :cache_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:fanfarr, :cache_dir)
      Application.delete_env(:fanfarr, :source_cache_max_bytes)
      Application.delete_env(:fanfarr, :source_cache_ttl_seconds)
    end)

    %{dir: dir}
  end

  # A real, tiny audio file: the cache computes a waveform on write, so a
  # fixture of arbitrary bytes would test nothing that matters.
  defp audio(seconds \\ 1) do
    dir = Path.join(System.tmp_dir!(), "fanfarr-audio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.mp3")

    {_out, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=#{seconds} -c:a libmp3lame) ++
          [path],
        stderr_to_stdout: true
      )

    path
  end

  test "a stored source comes back with its peaks" do
    assert {:ok, entry} = SourceCache.put(@url, audio(), :source)
    assert entry.kind == :source
    assert File.regular?(entry.path)

    assert {:ok, found} = SourceCache.fetch(@url)
    assert found.path == entry.path

    # The waveform is computed on write, so the editor never waits for it.
    assert %{"peaks" => [_ | _], "duration_ms" => ms} =
             found.peaks |> File.read!() |> Jason.decode!()

    assert ms > 0
  end

  test "an unknown url is a miss, not an error" do
    assert SourceCache.fetch(@url) == :miss
    assert SourceCache.fetch_source(@url) == :miss
  end

  test "the extension of the stored file is whatever arrived" do
    # The whole point of the cache is keeping the container YouTube served
    # rather than transcoding it to something we chose.
    source = audio()
    opus = String.replace_suffix(source, ".mp3", ".webm")
    File.rename!(source, opus)

    assert {:ok, entry} = SourceCache.put(@url, opus, :source)
    assert Path.extname(entry.path) == ".webm"
  end

  describe "the two kinds" do
    test "a render is fine to fetch and refused as a render source" do
      # A render is an mp3 we wrote earlier: good enough to listen to while
      # choosing a range, never good enough to render a written theme from.
      assert {:ok, _} = SourceCache.put(@url, audio(), :render)

      assert {:ok, %{kind: :render}} = SourceCache.fetch(@url)
      assert SourceCache.fetch_source(@url) == :miss
    end

    test "a source supersedes a render of the same url" do
      assert {:ok, _} = SourceCache.put(@url, audio(), :render)
      assert {:ok, _} = SourceCache.put(@url, audio(), :source)

      assert {:ok, %{kind: :source}} = SourceCache.fetch(@url)
      assert {:ok, _} = SourceCache.fetch_source(@url)
    end
  end

  describe "eviction" do
    test "anything past its age goes" do
      assert {:ok, entry} = SourceCache.put(@url, audio(), :source)

      # Backdate both halves of the entry past the limit.
      old = System.os_time(:second) - 10
      Application.put_env(:fanfarr, :source_cache_ttl_seconds, 1)
      File.touch!(entry.path, old)
      File.touch!(entry.peaks, old)

      SourceCache.sweep()

      assert SourceCache.fetch(@url) == :miss
      refute File.regular?(entry.path)
      # The peaks go with the audio: half an entry would be a file nothing
      # ever cleans up, over a url that reports a miss forever.
      refute File.regular?(entry.peaks)
    end

    test "the cap evicts oldest-first, and is what bounds a bulk run" do
      # The age limit does not bound anything on its own -- someone can edit
      # fifty titles in an afternoon. The byte cap is the real ceiling.
      assert {:ok, first} = SourceCache.put(@url, audio(2), :source)
      File.touch!(first.path, System.os_time(:second) - 100)
      File.touch!(first.peaks, System.os_time(:second) - 100)

      assert {:ok, second} = SourceCache.put(@other, audio(2), :source)

      # A cap that fits the newer entry -- audio *and* peaks, which is one
      # entry and is deleted as one -- and not both.
      newest = File.stat!(second.path).size + File.stat!(second.peaks).size
      Application.put_env(:fanfarr, :source_cache_max_bytes, newest)
      SourceCache.sweep()

      assert SourceCache.fetch(@url) == :miss, "the oldest entry should have been evicted"
      assert {:ok, _} = SourceCache.fetch(@other)
    end

    test "fetching keeps an entry alive" do
      # Least-recently-used, not oldest-written: a source someone keeps coming
      # back to should outlive one downloaded and abandoned.
      assert {:ok, entry} = SourceCache.put(@url, audio(), :source)
      old = System.os_time(:second) - 100
      File.touch!(entry.path, old)
      File.touch!(entry.peaks, old)

      assert {:ok, _} = SourceCache.fetch(@url)

      assert File.stat!(entry.path, time: :posix).mtime > old
    end
  end
end
