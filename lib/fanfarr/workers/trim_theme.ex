defmodule Fanfarr.Workers.TrimTheme do
  @moduledoc """
  Give an item's current theme a crop, then hand the write to `ApplyTheme`.

  A bulk selection cannot ask the question the item page asks, because the
  answer needs the audio: scoring every window of a track costs a download and
  seconds of decoding, and a hundred of those cannot happen inside a click. So
  the guessing happens here, one item at a time, on the queue that already
  exists for writing themes.

  Two things are deliberately left alone:

    * a crop the operator already chose. A guess does not outrank a decision,
      and skipping these is also what makes running it twice a no-op.

    * an item where no window could be found, and one with no theme to crop at
      all. Both are cancellations rather than failures -- retrying a track with
      no hook in it will not find one -- which is how `ApplyTheme` already
      treats an item it cannot plan for.

  The write itself is `ApplyTheme`'s, unchanged. One code path puts themes on
  disk; this is not a second one.
  """
  use Oban.Worker,
    queue: :apply,
    max_attempts: 3,
    unique: [period: 300, keys: [:media_item_id], states: [:available, :scheduled, :executing]]

  alias Fanfarr.Library
  alias Fanfarr.Themes.AutoCrop
  alias Fanfarr.Workers.ApplyTheme

  # The trimmer's own defaults, so a bulk crop fades the way a hand-made one
  # does. These are the browser's fallbacks in the hook -- see the Trimmer in
  # item_live -- and the two have to agree or the same crop would sound
  # different depending on which page asked for it.
  @default_fade_in_ms 250
  @default_fade_out_ms 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id}}) do
    item = Library.get_media_item!(item_id)

    case crop(item) do
      {:ok, trim} ->
        # Written to the item first: the apply worker reads the crop off the
        # item rather than out of its args, so this is what it will write.
        Library.set_theme_trim!(item, trim)
        ApplyTheme.enqueue(item)

      {:cancel, reason} ->
        {:cancel, reason}
    end
  end

  # Returns the crop to write, or why there is nothing to do. The cancellations
  # travel out through the `with` untouched, which is what makes a skip a skip
  # rather than three retries.
  defp crop(item) do
    with :ok <- enabled?(),
         :ok <- uncropped?(item) do
      case AutoCrop.suggest(item) do
        {:ok, suggestion} -> {:ok, trim_from(suggestion)}
        :no_suggestion -> {:cancel, :no_suggestion}
        {:error, reason} -> {:cancel, reason}
      end
    end
  end

  defp enabled? do
    if AutoCrop.enabled?(), do: :ok, else: {:cancel, :crop_disabled}
  end

  defp uncropped?(%{theme_start_ms: start, theme_end_ms: finish})
       when is_integer(start) and is_integer(finish),
       do: {:cancel, :already_cropped}

  defp uncropped?(_item), do: :ok

  defp trim_from(suggestion) do
    %{
      theme_start_ms: suggestion.start_ms,
      theme_end_ms: suggestion.end_ms,
      theme_fade_in_ms: @default_fade_in_ms,
      theme_fade_out_ms: @default_fade_out_ms
    }
  end
end
