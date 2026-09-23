defmodule Fanfarr.Workers.TrimTheme do
  @moduledoc """
  Give an item's current theme a crop, in place.

  A bulk selection cannot ask the question the item page asks, because the
  answer needs the audio: scoring every window of a track costs a download and
  seconds of decoding, and a hundred of those cannot happen inside a click. So
  the guessing happens here, one item at a time, on the queue that already
  exists for writing themes.

  ## It cuts the file that is there

  The theme is already on disk -- that is what "current theme" means -- so this
  cuts that file rather than fetching the source again. It is faster, it needs
  no network, and it costs one encode rather than the two a fresh apply costs
  (cut, then loudness).

  The price is that the cut is a lossy generation on a file that has already
  been through some: trim the same title five times and it carries five. That
  is what **Force redownload** on the item page is for -- it fetches the
  original again and starts over from one.

  ## What it leaves alone

    * a crop the operator already chose. A guess does not outrank a decision,
      and skipping these is also what makes running it twice a no-op.

    * an item with no local theme file. A Plex-supplied theme has nothing on
      disk to cut, and downloading one would be an apply rather than a trim.

    * an item where no window could be found. Retrying will not find one.
  """
  use Oban.Worker,
    queue: :apply,
    max_attempts: 3,
    unique: [period: 300, keys: [:media_item_id], states: [:available, :scheduled, :executing]]

  require Logger

  alias Fanfarr.Library
  alias Fanfarr.Themes
  alias Fanfarr.Themes.AutoCrop
  alias Fanfarr.Themes.Cutter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => item_id}}) do
    item = Library.get_media_item!(item_id)

    with :ok <- enabled?(),
         :ok <- uncropped?(item),
         {:ok, path} <- local_theme(item),
         {:ok, range} <- crop(item),
         {:ok, %{duration_ms: duration_ms}} <- cut(path, range) do
      # Two shapes of the same numbers: `Cutter` and the log take a range, the
      # item takes its attributes.
      Library.set_theme_trim!(item, %{
        theme_start_ms: range.start_ms,
        theme_end_ms: range.end_ms,
        theme_fade_in_ms: range.fade_in_ms,
        theme_fade_out_ms: range.fade_out_ms
      })

      record(item, path, range, duration_ms)
      broadcast(item)
      :ok
    else
      {:cancel, reason} ->
        # Logged on purpose. A skip is an answer rather than a fault, and
        # without this the only trace of one is a cancelled job with no
        # explanation on it -- which is what made a batch of them take a
        # database autopsy to understand.
        Logger.info(
          "[fanfarr] trim skipped for #{item.title}: #{skip_reason(reason)} " <>
            "(crop #{div(AutoCrop.target_ms(), 1000)}s)"
        )

        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # In the operator's terms rather than ours.
  defp skip_reason(:crop_disabled), do: "crop suggestions are turned off in Settings"
  defp skip_reason(:already_cropped), do: "it already has a crop"
  defp skip_reason(:no_local_theme), do: "there is no theme file beside the media to cut"
  defp skip_reason(:too_short), do: "it is shorter than the crop"
  defp skip_reason(:no_suggestion), do: "no window could be found in it"
  defp skip_reason(other), do: inspect(other)

  defp enabled? do
    if AutoCrop.enabled?(), do: :ok, else: {:cancel, :crop_disabled}
  end

  # Checked before the file, so a title that has been cropped says so whether
  # or not anything is on disk for it.
  defp uncropped?(%{theme_start_ms: start, theme_end_ms: finish})
       when is_integer(start) and is_integer(finish),
       do: {:cancel, :already_cropped}

  defp uncropped?(_item), do: :ok

  defp local_theme(%{local_theme_present: true, local_theme_path: path}) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:cancel, :no_local_theme}
  end

  defp local_theme(_item), do: {:cancel, :no_local_theme}

  defp crop(item) do
    # The configured floor is a policy for what is worth doing on its own. This
    # is not that: the operator picked these rows and pressed the button, so the
    # crop length is the only length that can veto -- a theme too short to hold
    # ninety seconds is declined, and one long enough is cropped whatever the
    # floor says.
    case AutoCrop.suggest(item, min_ms: AutoCrop.target_ms()) do
      {:ok, suggestion} -> {:ok, trim_from(suggestion)}
      :too_short -> {:cancel, :too_short}
      :no_suggestion -> {:cancel, :no_suggestion}
      {:error, reason} -> {:cancel, reason}
    end
  end

  # One encode, and deliberately not a second one: the file being cut has
  # already been through the loudness pass, and cutting preserves the level it
  # settled on. Re-normalising here would cost another generation to change
  # nothing.
  defp cut(path, trim) do
    case Themes.Cutter.cut(path, trim) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:cut_failed, reason}}
    end
  end

  # A row in the same append-only log as any other write, because the Size and
  # Length columns read the newest successful row rather than the file -- a
  # trim that recorded nothing would leave both reporting the length and the
  # size the theme used to have.
  defp record(item, path, range, duration_ms) do
    Themes.record_theme_outcome!(%{
      media_item_id: item.id,
      # `:local` because the origin of this write is the file already beside
      # the media, not a source that was fetched.
      source: :local,
      method: :local_file,
      theme_url: item.manual_theme_url || item.plex_theme_url,
      destination_path: path,
      start_ms: range.start_ms,
      end_ms: range.end_ms,
      status: :succeeded,
      codec: "mp3",
      bytes: File.stat!(path).size,
      duration_ms: duration_ms
    })
  end

  defp broadcast(item) do
    Phoenix.PubSub.broadcast(Fanfarr.PubSub, "item:#{item.id}", {:item_updated, item.id})
  end

  # A range, in the shape `Cutter` and the application log both take. The item
  # carries the same numbers under `theme_`-prefixed attributes.
  defp trim_from(suggestion) do
    %{
      start_ms: suggestion.start_ms,
      end_ms: suggestion.end_ms,
      fade_in_ms: Cutter.default_fade_in_ms(),
      fade_out_ms: Cutter.default_fade_out_ms()
    }
  end
end
