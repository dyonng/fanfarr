defmodule Fanfarr.Themes.Downloader do
  @moduledoc """
  Turning a ThemerrDB YouTube URL into an audio file on disk.

  A behaviour for the same reason the Plex client is one: the test suite must
  never reach YouTube, and the seam is where a second resolver (a direct file
  URL, a local library) arrives later.

  ## Why yt-dlp is not called inline

  YouTube changes often enough to break extraction, so the binary's version
  moves independently of ours -- it is installed from its own release in the
  Dockerfile and can be replaced without rebuilding the app. That also means
  it fails in more ways than most dependencies, and every one of them has to
  come back as a value rather than an exception.
  """

  @typedoc """
  What a successful download produced.

  `codec` and `duration` come from the file that was actually written, not
  from what was asked for, because the point of recording them is to notice
  when they differ.
  """
  @type result :: %{
          path: Path.t(),
          bytes: non_neg_integer(),
          codec: String.t() | nil,
          duration: number() | nil
        }

  @type error ::
          :not_installed
          | :unsupported_url
          | :timeout
          | :too_long
          | :too_large
          | :unavailable
          | {:exit, integer(), String.t()}

  @doc """
  Downloads the audio at `url` into `dir`, returning the file it wrote.

  `dir` must already exist and be writable. The implementation is responsible
  for leaving nothing behind on failure.
  """
  @callback download(url :: String.t(), dir :: Path.t()) :: {:ok, result()} | {:error, error()}

  @doc """
  Whether the downloader can run at all, and what version.

  Surfaced on the settings page: a missing binary should read as a
  configuration problem, not as every download mysteriously failing.
  """
  @callback version() :: {:ok, String.t()} | {:error, error()}

  @doc "The configured implementation. Tests set :theme_downloader to the mock."
  def impl, do: Application.get_env(:fanfarr, :theme_downloader, Fanfarr.Themes.Downloader.YtDlp)
end
