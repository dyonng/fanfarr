defmodule Fanfarr.Themes.SourceCache do
  @moduledoc """
  Keeps the untranscoded source audio of recently edited themes, so trimming
  one does not re-download it on every drag of a handle.

  ## What is cached, and why not "lossless"

  The original stream, exactly as YouTube served it -- Opus or AAC in whatever
  container it arrived in. Not an mp3 and not a WAV.

  Fanfarr never has lossless audio: YouTube is lossy at the source, and the
  apply path currently transcodes that to mp3. Decoding it further to WAV to
  call the cache "lossless" would be lossless only with respect to the mp3, at
  roughly ten times the size, with no fidelity gained. Keeping what arrived is
  both smaller and better -- and it removes a generation from the trim path,
  because a cut then goes source -> cut -> mp3 rather than source -> mp3 ->
  cut -> mp3.

  ## What it costs, and the cap that bounds it

  A two-minute theme is around 2 MB as Opus. The cap is the important part,
  not the age limit: the sharp edge is a bulk apply, which would otherwise
  drop a gigabyte of source audio into the volume for a run nobody is editing.
  So there are two rules and both matter:

    * this is populated on the **edit** path only. `ApplyTheme` never writes
      here.
    * eviction is oldest-first against a byte cap, and separately anything
      past its age. The cap is what makes the worst case finite.

  ## Keying, and the two kinds of entry

  On a hash of the source URL rather than the item id. Two titles can share a
  theme, re-picking the same video should hit rather than re-download, and a
  hashed name means a hostile URL cannot shape a path. Nothing here is served
  to a browser by name.

  An entry is one of two kinds, and the filename says which:

    * `:source` -- the stream as YouTube served it. Good enough to render the
      applied theme from, so `ApplyTheme` will use one rather than downloading
      again. That is what makes trim-then-apply fast.

    * `:render` -- an mp3 Fanfarr previously wrote for this URL, seeded from
      the file next to the media when someone edits a theme that was applied
      whole. It is a generation down and already loudness-normalised, so it is
      fine to *listen* to while choosing a range and must never be the source
      of a written theme. Nothing reads it but the editor.

  A `:source` entry supersedes a `:render` one for the same URL.
  """

  require Logger

  alias Fanfarr.Themes.Waveform

  @type kind :: :source | :render

  # Three days, which is about how long an editing session's second thoughts
  # last. The cap below is what actually bounds the directory.
  @default_ttl_seconds 3 * 24 * 3600
  @default_max_bytes 2 * 1024 * 1024 * 1024

  @doc "Where cached sources live: beside the database, like the poster cache."
  def dir do
    Application.get_env(:fanfarr, :cache_dir, Path.join(System.tmp_dir!(), "fanfarr-cache"))
    |> Path.join("sources")
  end

  @doc """
  The cached entry for a URL, or `:miss`.

  Touches the entry on a hit so eviction is least-recently-used rather than
  oldest-written: a source someone keeps coming back to should outlive one
  they downloaded and abandoned.
  """
  @spec fetch(String.t()) :: {:ok, %{path: Path.t(), peaks: Path.t(), kind: kind()}} | :miss
  def fetch(url) when is_binary(url) do
    key = key(url)

    # :source first: it supersedes a render of the same URL.
    Enum.find_value([:source, :render], :miss, fn kind ->
      case audio_path(key, kind) do
        nil ->
          nil

        path ->
          peaks = peaks_path(key, kind)

          if File.regular?(peaks) do
            touch(path)
            touch(peaks)
            {:ok, %{path: path, peaks: peaks, kind: kind}}
          else
            # Audio with no peaks is half an entry: the editor would have
            # nothing to draw. Treated as absent rather than as a hit.
            nil
          end
      end
    end)
  end

  @doc """
  The cached original for a URL, or `:miss`.

  What `ApplyTheme` asks, and deliberately narrower than `fetch/1`: a
  `:render` entry is a previous output and rendering from it would compound
  the losses it already carries.
  """
  @spec fetch_source(String.t()) :: {:ok, Path.t()} | :miss
  def fetch_source(url) when is_binary(url) do
    case fetch(url) do
      {:ok, %{path: path, kind: :source}} -> {:ok, path}
      _ -> :miss
    end
  end

  defp audio_path(key, kind) do
    Path.join(dir(), "#{key}.#{kind}.*")
    |> Path.wildcard()
    |> Enum.reject(&(&1 =~ ~r/\.peaks\.json$/))
    |> List.first()
  end

  @doc """
  Stores `source` (moved, not copied) and computes its waveform peaks.

  Takes the extension from the file it is given, because the whole point is to
  keep the container the download arrived in.
  """
  @spec put(String.t(), Path.t(), kind()) ::
          {:ok, %{path: Path.t(), peaks: Path.t(), kind: kind()}} | {:error, term()}
  def put(url, source, kind) when kind in [:source, :render] do
    key = key(url)
    File.mkdir_p!(dir())

    target = Path.join(dir(), "#{key}.#{kind}#{Path.extname(source)}")
    peaks = peaks_path(key, kind)

    with :ok <- Fanfarr.Themes.Writer.place(source, target),
         {:ok, _} <- Waveform.write(target, peaks) do
      sweep()
      {:ok, %{path: target, peaks: peaks, kind: kind}}
    else
      {:error, reason} ->
        File.rm(target)
        File.rm(peaks)
        {:error, reason}
    end
  end

  @doc """
  Drops anything past its age, then evicts oldest-first until under the cap.

  Called after every write and from the scheduler's heartbeat. Cheap: one
  directory listing and a stat per file, over a directory holding tens of
  entries.
  """
  @spec sweep() :: :ok
  def sweep do
    entries = entries()
    cutoff = System.os_time(:second) - ttl_seconds()
    {stale, fresh} = Enum.split_with(entries, &(&1.mtime < cutoff))

    Enum.each(stale, &remove/1)

    fresh
    |> Enum.sort_by(& &1.mtime)
    |> evict_to_cap(Enum.reduce(fresh, 0, &(&2 + &1.size)))

    :ok
  end

  # Grouped into entries before anything is counted, because an entry is the
  # audio *and* its peaks and they are deleted together. Counting them as two
  # rows and deleting them as one made the eviction loop over-subtract, so a
  # cap that should have kept the newest entry threw it away too.
  #
  # The pair's mtime is the newer of the two: `fetch/1` touches both, and using
  # the older would age an entry that is in active use.
  defp entries do
    Path.join(dir(), "*")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{type: :regular, size: size, mtime: mtime}} ->
          [%{base: base(path), path: path, size: size, mtime: mtime}]

        _ ->
          []
      end
    end)
    |> Enum.group_by(& &1.base)
    |> Enum.map(fn {base, files} ->
      %{
        base: base,
        size: Enum.reduce(files, 0, &(&2 + &1.size)),
        mtime: files |> Enum.map(& &1.mtime) |> Enum.max()
      }
    end)
  end

  defp evict_to_cap(_entries, total) when total <= 0, do: :ok

  defp evict_to_cap(entries, total) do
    cap = max_bytes()

    Enum.reduce_while(entries, total, fn entry, remaining ->
      if remaining <= cap do
        {:halt, remaining}
      else
        remove(entry)
        {:cont, remaining - entry.size}
      end
    end)

    :ok
  end

  # "<key>.<kind>", shared by the audio and its peaks.
  defp base(path) do
    path
    |> String.replace_suffix(".peaks.json", "")
    |> Path.rootname()
  end

  defp remove(%{base: base}) do
    Path.wildcard(base <> ".*") |> Enum.each(&File.rm/1)
    :ok
  end

  @doc "How long an untouched source is kept."
  def ttl_seconds do
    Application.get_env(:fanfarr, :source_cache_ttl_seconds, @default_ttl_seconds)
  end

  @doc "The ceiling the directory is held under, oldest evicted first."
  def max_bytes do
    Application.get_env(:fanfarr, :source_cache_max_bytes, @default_max_bytes)
  end

  defp peaks_path(key, kind), do: Path.join(dir(), "#{key}.#{kind}.peaks.json")

  defp key(url), do: :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)

  defp touch(path) do
    now = System.os_time(:second)
    _ = File.touch(path, now)
    :ok
  end
end
