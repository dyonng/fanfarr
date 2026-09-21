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
  # A track this close to the target is not worth a re-encode.
  @worth_cropping_ratio 1.5

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
  def target_ms do
    case Fanfarr.Config.get("auto_crop_target_ms") do
      value when is_binary(value) ->
        case value |> String.trim() |> Integer.parse() do
          {ms, ""} when ms > 0 -> ms
          _ -> @default_target_ms
        end

      _ ->
        @default_target_ms
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

  `{:error, :no_url}` when nothing knows of a theme for this item at all, and
  `:no_suggestion` when there is one but no signal could place a window in it.
  """
  @spec suggest(Fanfarr.Library.MediaItem.t(), keyword()) ::
          {:ok, suggestion()} | {:error, term()} | :no_suggestion
  def suggest(item, opts \\ []) do
    target = Keyword.get(opts, :target_ms, target_ms())

    with {:ok, url, _origin} <- Choice.url(item, %{}) do
      case from_graph(url, target) do
        {:ok, suggestion} -> {:ok, suggestion}
        :no_signal -> from_audio(item, target)
      end
    end
  end

  # --- the graph -----------------------------------------------------------

  defp from_graph(url, target) do
    with true <- Downloader.youtube_url?(url),
         {:ok, markers} <- Downloader.impl().heatmap(url),
         {:ok, window} <- MostReplayed.best_window(markers, target) do
      {:ok,
       %{
         start_ms: window.start_ms,
         end_ms: window.end_ms,
         source: :most_replayed,
         score: window.score
       }}
    else
      # A video with no graph, or a downloader that cannot say. Either way the
      # audio is still there to be asked.
      _ -> :no_signal
    end
  end

  # --- the audio -----------------------------------------------------------

  defp from_audio(item, target) do
    case EditSource.resolve(item) do
      {:ok, %{path: path}} -> suggest_from_audio(path, target_ms: target)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The window the audio itself suggests, for a file already on disk.

  Separate from `suggest/2` so the analysis can be exercised against a fixture
  instead of whatever YouTube would serve today, and so a caller that already
  has the audio -- the trim editor does -- can ask without a second resolve.
  """
  @spec suggest_from_audio(Path.t(), keyword()) :: {:ok, suggestion()} | :no_suggestion
  def suggest_from_audio(path, opts \\ []) do
    target = Keyword.get(opts, :target_ms, target_ms())

    with {:ok, pcm} <- Pcm.decode(path) do
      analyse(features(pcm), target)
    end
  end

  defp analyse(frames, target) do
    cond do
      frames == [] ->
        :no_suggestion

      length(frames) * @frame_ms < target * @worth_cropping_ratio ->
        # Nothing to save, and a re-encode to shave ten seconds off is a
        # generation of lossy loss for a rounding error.
        :no_suggestion

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
