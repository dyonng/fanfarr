defmodule Fanfarr.Themes.MostReplayed do
  @moduledoc """
  Picking the iconic part of a track from YouTube's own viewership graph.

  YouTube publishes a "most replayed" graph for most videos -- a hundred
  buckets across the timeline, each with the share of viewers who were
  watching there. For a theme that is the question answered directly: the
  bucket people scrub back to *is* the hook, and no amount of local signal
  processing beats asking.

  It is not always there. The graph arrives once a video has enough views, and
  some uploads never have it at all -- measured across this library's themes it
  was present on about three in five (5 of 8 sampled, and the misses were the
  low-view-count uploads). So this is the first choice, not the only one:
  `AutoCrop` falls through to analysing the audio when it returns
  `:no_signal`.

  `yt-dlp` does the fetching and the parsing (`heatmap` in its info dict,
  upstream since its own 2023 change); this module only decides which window
  of the graph to trust.
  """

  @typedoc "One bucket of the graph, as yt-dlp reports it."
  @type marker :: %{start_time: number(), end_time: number(), value: number()}

  @typedoc "A window of the timeline, chosen for how much attention it holds."
  @type window :: %{start_ms: non_neg_integer(), end_ms: non_neg_integer(), score: float()}

  @doc """
  The `length_ms`-long window of the graph holding the most attention.

  Summed rather than averaged, and the window is placed by sliding over whole
  markers: the graph's own resolution is the honest granularity here, and
  interpolating between buckets would invent detail the data does not have.
  """
  @spec best_window([marker()], non_neg_integer()) :: {:ok, window()} | :no_signal
  def best_window(markers, length_ms)

  def best_window(markers, length_ms) when is_list(markers) and markers != [] do
    beats =
      markers
      |> Enum.filter(&(number?(&1[:start_time]) and number?(&1[:end_time])))
      |> Enum.map(
        &%{
          start_ms: round(&1.start_time * 1000),
          end_ms: round(&1.end_time * 1000),
          value: &1.value || 0.0
        }
      )
      |> Enum.sort_by(& &1.start_ms)

    span = Enum.reduce(beats, 0, fn beat, acc -> max(acc, beat.end_ms - beat.start_ms) end)

    if beats == [] or span <= 0 do
      :no_signal
    else
      # A window covering `count` consecutive buckets, walked from each start.
      count = max(div(length_ms, span), 1)
      starts = 0..max(length(beats) - count, 0)

      starts
      |> Enum.flat_map(fn index -> window_at(beats, index, count) end)
      |> case do
        [] -> :no_signal
        windows -> {:ok, Enum.max_by(windows, & &1.score)}
      end
    end
  end

  def best_window(_markers, _length_ms), do: :no_signal

  @doc """
  How long the graph covers, which is the video's own length.

  This is what lets a track already shorter than the crop be declined before
  anything is fetched: the graph is the only length available at that point,
  and for the audio path the decode answers the same question.
  """
  @spec duration_ms([marker()]) :: non_neg_integer()
  def duration_ms(markers) when is_list(markers) do
    markers
    |> Enum.map(& &1[:end_time])
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.*(1000)
    |> round()
  end

  def duration_ms(_markers), do: 0

  # The window of `count` buckets starting at `index`, or nothing when the
  # graph runs out first: the tail of a track is not a full window.
  defp window_at(beats, index, count) do
    case Enum.slice(beats, index, count) do
      window when length(window) == count ->
        [
          %{
            start_ms: hd(window).start_ms,
            end_ms: List.last(window).end_ms,
            score: Enum.reduce(window, 0.0, &(&2 + &1.value)) / count
          }
        ]

      _ ->
        []
    end
  end

  defp number?(value), do: is_number(value)
end
