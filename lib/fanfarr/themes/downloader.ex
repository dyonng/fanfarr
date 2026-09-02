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

  @typedoc "One search hit, enough to judge it without leaving the page."
  @type hit :: %{
          id: String.t(),
          url: String.t(),
          title: String.t(),
          channel: String.t() | nil,
          duration: number() | nil,
          thumbnail: String.t() | nil,
          view_count: non_neg_integer() | nil
        }

  @doc """
  Searches YouTube and returns up to `limit` hits.

  ThemerrDB covers a fraction of any real library, and the operator's stated
  job is finding themes for the shows it does not know. Searching from inside
  the app means the choice and the apply are one flow, and the URL that gets
  applied is the one that was previewed -- not one retyped from another tab.
  """
  @callback search(query :: String.t(), limit :: pos_integer()) ::
              {:ok, [hit()]} | {:error, error()}

  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be)

  @doc """
  Whether a URL is one we will hand to the downloader at all.

  The allowlist matters because these URLs arrive from a third-party database
  and from a text field, and yt-dlp accepts local paths and other protocols.
  """
  @spec youtube_url?(term()) :: boolean()
  def youtube_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host) in @youtube_hosts

      _ ->
        false
    end
  end

  def youtube_url?(_), do: false

  @doc "The 11-character video id, for the embedded preview; nil if there is none."
  @spec youtube_id(term()) :: String.t() | nil
  def youtube_id(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    id =
      cond do
        uri.host in ["youtu.be"] ->
          uri.path && String.trim_leading(uri.path, "/")

        is_binary(uri.query) ->
          uri.query |> URI.decode_query() |> Map.get("v")

        is_binary(uri.path) and String.contains?(uri.path, "/embed/") ->
          uri.path |> String.split("/embed/") |> List.last()

        true ->
          nil
      end

    if is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]{11}$/, id), do: id
  end

  def youtube_id(_), do: nil

  @doc "The configured implementation. Tests set :theme_downloader to the mock."
  def impl, do: Application.get_env(:fanfarr, :theme_downloader, Fanfarr.Themes.Downloader.YtDlp)
end
