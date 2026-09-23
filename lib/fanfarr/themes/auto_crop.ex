defmodule Fanfarr.Themes.AutoCrop do
  @moduledoc """
  Where the iconic part of a theme is, so a snippet can be written instead of
  the whole track.

  A theme is looped in a detail page, not listened to. An eleven-minute
  orchestral piece is 14 MB of library disk to play ninety seconds of, and the
  part worth keeping is usually a chorus or a hook that the rest of the track
  is built around. This decides which window that is; `Fanfarr.Themes.Cutter`
  already knows how to cut it, fades and all.

  ## Signal order

  Asked in order, first answer wins -- and the order is the whole design:

    1. **The most-replayed graph** (`Fanfarr.Themes.MostReplayed`). Viewers
       skipping back to a moment is the question answered directly, and it
       beats anything measurable locally. Present on roughly three in five
       themes; absent on low-view uploads.

    2. **The audio itself.** A chorus repeats and is loud, so a window is
       scored on how much it resembles other windows of the same track, plus
       an energy prior, exactly as a person would describe the hook. Slower to
       get (one decode) but always available, offline, and with no new
       dependency.

   3. Chapters were measured and dropped: `%(chapters)j` came back empty on 8
       of 8 sampled themes. A signal that never fires is not worth a probe.

  ## Boundaries

  Whichever signal chose the window, the start is nudged onto the quietest
  frame within `@snap_ms` of it, so the cut lands in a gap rather than through
  the middle of a phrase. The fades `Cutter` applies then cover what is left.

  ## It proposes, it does not write

  Nothing here applies anything. It returns a range, the item page puts it in
  the trim editor marked as automatic, and the operator presses Apply. A crop
  is a judgement about music, and this is a guess about music.
  """

  alias Fanfarr.Themes.Choice
  alias Fanfarr.Themes.Downloader
  alias Fanfarr.Themes.EditSource
  alias Fanfarr.Themes.MostReplayed
  alias Fanfarr.Themes.Pcm

  require Logger

  # Ninety seconds: long enough to be the piece rather than a fragment, short
  # enough that an eleven-minute suite stops costing 14 MB of library disk.
  @default_target_ms 90_000
  @frame_ms 1_000
  @snap_ms 2_000

  @typedoc "A window worth writing, and what decided it."
  @type suggestion :: %{
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer(),
          source: :most_replayed | :audio,
          score: float()
        }

  @doc """
  How long a written theme should be, in milliseconds.

  Read through `Fanfarr.Config`, the way every other operator setting is: the
  dashboard value wins over `AUTO_CROP_TARGET_MS`, and the default above applies
  when neither is set. A value that is not a number falls back rather than
  taking the feature down with it.
  """
  @spec target_ms() :: pos_integer()
  def target_ms, do: ms_setting("auto_crop_target_ms") || @default_target_ms

  @doc """
  The shortest a theme may be and still be worth cropping, as configured.

  What the settings page shows and what a plain call resolves to. A call that
  overrides the target length also moves the floor with it -- see `floor_for/2`
  -- because a floor left behind at the configured value would let a longer
  target produce a window longer than the track.
  """
  @spec min_ms() :: pos_integer()
  def min_ms, do: ms_setting("auto_crop_min_ms") || target_ms()

  # An explicit option wins, then the operator's setting, then the target this
  # call is actually using.
  defp floor_for(target, opts) do
    Keyword.get(opts, :min_ms) || ms_setting("auto_crop_min_ms") || target
  end

  @doc """
  Whether to ask YouTube's viewership graph before analysing the audio.

  On by default, and the first choice when it is: viewers skipping back to a
  moment answers the question directly. Off for an install that would rather
  not reach a third party from the item page, or whose library mostly has no
  graph anyway -- the audio analysis is local and always available.

  Only a setting that says so turns it off, so an unset or half-typed value
  leaves the better signal in place.
  """
  @spec use_graph?() :: boolean()
  def use_graph?, do: Fanfarr.Config.get("auto_crop_graph") not in ["false", "0", "off"]

  @doc """
  Whether the feature is offered at all.

  Off, the item page stops offering a suggestion and `suggest/2` refuses, so
  nothing is fetched from YouTube and nothing is decoded. Trimming by hand is
  untouched: this switches off the automatic part, not the editor.

  `suggest_from_audio/2` is deliberately not gated. It is the mechanism the
  suggestion is built on rather than the offer itself, and it has callers of
  its own.

  On by default, like the graph: only a setting that says so turns it off, so
  an unset or half-typed value does not quietly disable a feature.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Fanfarr.Config.get("auto_crop_enabled") not in ["false", "0", "off"]

  # One reader for a millisecond setting, so the parsing and the fallback live
  # in one place rather than beside each caller.
  defp ms_setting(key) do
    case Fanfarr.Config.get(key) do
      value when is_binary(value) ->
        case value |> String.trim() |> Integer.parse() do
          {ms, ""} when ms > 0 -> ms
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Roughly what `target_ms` of audio costs at the writer's bitrate, for the
  page to say what the saving would be before anything is written.
  """
  @spec projected_bytes(pos_integer(), pos_integer()) :: non_neg_integer()
  def projected_bytes(target_ms, bitrate \\ 192_000), do: div(target_ms * bitrate, 8000)

  @doc """
  A crop for `item`: the iconic window, or why there is not one.

  `{:error, :no_url}` when nothing knows of a theme for this item at all,
  `:too_short` when the theme cannot hold the crop at all, `:no_suggestion`
  when it can but no signal could place a window in it, and `{:error,
  :disabled}` when the operator has turned the feature off.
  """
  @spec suggest(Fanfarr.Library.MediaItem.t(), keyword()) ::
          {:ok, suggestion()} | {:error, term()} | :too_short | :no_suggestion
  def suggest(item, opts \\ []) do
    target = Keyword.get(opts, :target_ms, target_ms())
    floor = floor_for(target, opts)

    # Asked here rather than only in the page that draws the button, so a
    # caller added later cannot route around the operator's answer.
    if enabled?() do
      with {:ok, url, _origin} <- Choice.url(item, %{}) do
        case from_graph(url, target) do
          {:ok, suggestion} -> {:ok, suggestion}
          # The graph is the fast answer, never the only one. Absent,
          # unreadable, too short to hold the crop, or turned off all arrive
          # here as the same miss, and the audio answers next.
          :no_signal -> from_audio(item, target, floor)
        end
      end
    else
      {:error, :disabled}
    end
  end

  # --- the graph -----------------------------------------------------------

  defp from_graph(url, target) do
    with true <- use_graph?(),
         true <- Downloader.youtube_url?(url),
         {:ok, markers} <- Downloader.impl().heatmap(url),
         {:ok, window} <- from_heatmap(markers, target) do
      {:ok,
       %{
         start_ms: window.start_ms,
         end_ms: window.end_ms,
         source: :most_replayed,
         score: window.score
       }}
    else
      # A video with no graph, or a downloader that cannot say, or the graph
      # turned off. Either way the audio is still there to be asked.
      _ ->
        :no_signal
    end
  end

  # The extent of a graph is not the length of a track. It covers only the part
  # viewers replayed enough to appear in it, so a 275-second theme can answer
  # with a hundred seconds of graph -- and reading that as "too short" declined
  # it *without asking the audio*, which is the fallback that exists for exactly
  # this case. Measured: Inception, 275s of theme, full decode, a good window at
  # 56s, and declined anyway.
  #
  # So a graph that does not reach far enough is a miss rather than a verdict.
  # `best_window/2` still declines a graph too short to hold the crop itself,
  # which is the only length question the graph can honestly answer.
  defp from_heatmap(markers, target) do
    MostReplayed.best_window(markers, target)
  end

  # --- the audio -----------------------------------------------------------

  defp from_audio(item, target, floor) do
    case EditSource.resolve(item) do
      {:ok, %{path: path}} -> suggest_from_audio(path, target_ms: target, min_ms: floor)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The window the audio itself suggests, for a file already on disk.

  Separate from `suggest/2` so the analysis can be exercised against a fixture
  instead of whatever YouTube would serve today, and so a caller that already
  has the audio -- the trim editor does -- can ask without a second resolve.

  `:too_short` when the file cannot hold the crop, and `:no_suggestion` when
  it can but no window stood out of the rest. Two answers rather than one
  because the first is a length and the second is a listen, and a caller that
  reports a skip is more useful when it can say which happened.
  """
  @spec suggest_from_audio(Path.t(), keyword()) ::
          {:ok, suggestion()} | :too_short | :no_suggestion
  def suggest_from_audio(path, opts \\ []) do
    target = Keyword.get(opts, :target_ms, target_ms())
    floor = floor_for(target, opts)

    with {:ok, pcm} <- Pcm.decode(path) do
      analyse(features(pcm), target, floor)
    end
  end

  defp analyse(frames, target, floor) do
    cond do
      frames == [] ->
        :no_suggestion

      length(frames) * @frame_ms < floor ->
        # Shorter than the crop is worth, which is its own answer rather than a
        # failure to find one: nothing to save, and a re-encode would cost a
        # generation of lossy loss for a few seconds. Named so a caller that
        # skips the file can say which of the two happened.
        :too_short

      true ->
        case best_window(frames, div(target, @frame_ms)) do
          nil ->
            :no_suggestion

          window ->
            start = snap(frames, window.start_ms)

            {:ok,
             %{
               start_ms: start,
               end_ms: start + target,
               source: :audio,
               score: window.score
             }}
        end
    end
  end

  # Loudness and zero-crossing rate per frame: a verse and a chorus differ in
  # both, and neither costs more than a walk over the samples. ZCR is a crude
  # stand-in for brightness -- a dense chorus crosses zero far more often than
  # a sparse intro -- and it is the cheapest feature that separates them.
  defp features(pcm) do
    bytes_per_frame = div(Pcm.rate() * @frame_ms, 1000) * 2

    for <<frame::binary-size(bytes_per_frame) <- pcm>> do
      {sum, crosses, _previous} =
        for <<sample::little-signed-16 <- frame>>, reduce: {0, 0, 0} do
          {sum, crosses, previous} ->
            {sum + sample * sample, crosses + crossing(previous, sample), sample}
        end

      count = div(bytes_per_frame, 2)

      %{
        rms: :math.sqrt(sum / count) / 32768,
        crossings: crosses / count
      }
    end
  end

  defp crossing(previous, sample) do
    if (previous < 0 and sample >= 0) or (previous >= 0 and sample < 0), do: 1, else: 0
  end

  # The window whose shape most resembles other windows of the same track --
  # a chorus is the part that keeps coming back -- but scored energy-first.
  # Repetition alone prefers a quiet motif that happens to recur over a loud
  # passage that does not, and that is the wrong way round for a theme: the
  # hook is the loud part, and a repeated quiet one is usually just an
  # accompaniment figure. Repetition breaks ties among the loud candidates.
  #
  # Both features are standardised first, so neither can be swamped by whatever
  # scale the decoder happened to produce.
  defp best_window(frames, count) when count >= 1 do
    rms = standardise(Enum.map(frames, & &1.rms))
    crossings = standardise(Enum.map(frames, & &1.crossings))
    starts = 0..max(length(frames) - count, 0)
    vectors = Map.new(starts, fn at -> {at, window_vector(rms, crossings, at, count)} end)

    starts
    |> Enum.map(fn at ->
      %{
        start_ms: at * @frame_ms,
        end_ms: (at + count) * @frame_ms,
        score: mean(Enum.slice(rms, at, count)) + 0.5 * repetition(vectors, at, count)
      }
    end)
    |> Enum.max_by(& &1.score, fn -> nil end)
  end

  # Compared against every fifth window: a chorus is long, so comparing against
  # all of them buys nothing but a slower answer.
  defp repetition(vectors, at, count) do
    mine = vectors[at]

    similarities =
      vectors
      |> Enum.filter(fn {other, _} -> abs(other - at) >= count and rem(other, 5) == 0 end)
      |> Enum.map(fn {_, theirs} -> cosine(mine, theirs) end)
      |> Enum.sort(:desc)
      |> Enum.take(3)

    case similarities do
      [] -> 0.0
      list -> Enum.sum(list) / length(list)
    end
  end

  defp window_vector(rms, crossings, at, count) do
    Enum.flat_map(0..(count - 1), fn offset ->
      [Enum.at(rms, at + offset, 0.0), Enum.at(crossings, at + offset, 0.0)]
    end)
  end

  defp cosine(a, b) do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    magnitude = :math.sqrt(na) * :math.sqrt(nb)

    # A comparison rather than a match: 0.0 is a float literal, and matching on
    # one is only equivalent to matching +0.0 since OTP 27.
    if magnitude == 0.0, do: 0.0, else: dot / magnitude
  end

  # Within a couple of seconds of the chosen start, prefer the quietest frame:
  # a cut through a held note is audible even under a fade.
  defp snap(frames, start_ms) do
    at = div(start_ms, @frame_ms)
    radius = div(@snap_ms, @frame_ms)
    lo = max(at - radius, 0)
    hi = min(at + radius, length(frames) - 1)

    lo..hi
    |> Enum.min_by(fn index -> Enum.at(frames, index).rms end)
    |> Kernel.*(@frame_ms)
  end

  defp standardise(values) do
    count = length(values)
    mean = mean(values)

    deviation =
      :math.sqrt(Enum.sum(Enum.map(values, &((&1 - mean) * (&1 - mean)))) / max(count, 1))

    if deviation == 0.0,
      do: Enum.map(values, fn _ -> 0.0 end),
      else: Enum.map(values, &((&1 - mean) / deviation))
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)
end
