defmodule Fanfarr.Plex.Client do
  @moduledoc """
  The boundary between Fanfarr and a media server.

  A behaviour for two reasons. Tests replace it with a Mox mock, so the sync
  and apply pipelines are exercised without a Plex server in reach. And the
  brief requires that Jellyfin support, while out of scope, not be made
  impossible -- everything above this line speaks in these terms and nothing
  above it knows it is talking to Plex.

  Implementations are chosen at runtime via `impl/0`.
  """

  @type config :: %{base_url: String.t(), token: String.t()}

  @type section :: %{
          key: String.t(),
          title: String.t(),
          kind: :show | :movie,
          locations: [String.t()]
        }

  @type item :: %{
          rating_key: String.t(),
          title: String.t(),
          year: integer() | nil,
          kind: :show | :movie,
          guid: String.t() | nil,
          imdb_id: String.t() | nil,
          tmdb_id: String.t() | nil,
          tvdb_id: String.t() | nil,
          path: String.t() | nil,
          thumb: String.t() | nil,
          theme: String.t() | nil,
          added_at: DateTime.t() | nil
        }

  # Plex reports no `provider` field; origin is derived from the ratingKey's
  # URI scheme instead. See Fanfarr.Plex.ThemeOrigin.
  @type theme :: %{
          rating_key: String.t() | nil,
          key: String.t() | nil,
          selected: boolean(),
          origin: Fanfarr.Plex.ThemeOrigin.t(),
          agent: String.t() | nil
        }

  @doc "Server identity; doubles as the connection test for Settings."
  @callback server_info(config) ::
              {:ok, %{name: String.t(), version: String.t()}} | {:error, term()}

  @callback sections(config) :: {:ok, [section()]} | {:error, term()}
  @callback items(config, section_key :: String.t()) :: {:ok, [item()]} | {:error, term()}
  @callback themes(config, rating_key :: String.t()) :: {:ok, [theme()]} | {:error, term()}

  @doc """
  Uploads a theme. IRREVERSIBLE: Plex has no API to delete a theme, so callers
  go through the application log's intent/outcome pair, never call this
  directly from UI code, and honour dry-run before reaching this point.
  """
  @callback upload_theme(config, rating_key :: String.t(), {:url, String.t()} | {:file, Path.t()}) ::
              :ok | {:error, term()}

  @callback lock_theme(config, rating_key :: String.t(), library_type_id :: integer()) ::
              :ok | {:error, term()}

  @doc """
  Asks Plex to re-read an item's metadata, which is what makes it notice a
  theme file that appeared next to the media after the last scan.

  Plex does not watch the filesystem for local assets; without this the file
  sits there unnoticed until something else triggers a refresh.
  """
  @callback refresh_metadata(config, rating_key :: String.t()) :: :ok | {:error, term()}

  @doc """
  Asks Plex's *scanner* to walk one directory again.

  Distinct from `refresh_metadata/2`, and the distinction is the whole reason
  this exists. Plex separates finding files from fetching metadata about them:
  the scanner walks the filesystem, and the agents run afterwards over what the
  scanner found. `refresh_metadata/2` only re-runs the second stage, so a
  sidecar file written since the last scan -- `theme.mp3`, exactly our case --
  is invisible to it. The agents faithfully re-derive a theme from a file
  listing that does not yet mention ours.

  `path` is a directory in **Plex's** view of the filesystem, so pass
  `plex_path` and not the mapped local path.
  """
  @callback scan_directory(config, section_key :: String.t(), path :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Promotes one of an item's existing themes to *the* theme.

  Plex can hold several themes for an item and serve none of them, which is
  where a freshly scanned `theme.mp3` sits: listed, unselected, silent. This
  is the call that picks one, and it adds nothing -- the theme must already be
  in the item's list, so the only thing it changes is which of them plays.

  Singular `theme` selects; the plural `themes` on `upload_theme/3` adds. That
  is Plex's own convention for posters and art, and it is **inferred** here
  rather than verified, so callers should read the item back afterwards and
  report what Plex actually did rather than assuming a 200 means success.
  """
  @callback select_theme(config, rating_key :: String.t(), theme_rating_key :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  A raw GET against the configured server, for the System page's diagnostics.

  Always relative to the configured `base_url`, so this reaches the operator's
  own Plex and nowhere else. It exists because the fastest way to settle what
  Plex does or does not report is to look at what it actually sent.
  """
  @callback raw(config, path :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Raw metadata for one item, exactly as Plex returns it.

  Used to recover a path the section listing did not carry, and by the
  diagnostics on the System page -- where seeing the server's actual response
  beats any amount of reasoning about what it ought to contain.
  """
  @callback metadata(config, rating_key :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  The directory an item's files live in, for items the listing did not say.

  A section listing gives movies a `Media/Part/file` and is supposed to give
  shows a `Location`. When it gives neither there is no path to write a theme
  beside, so this asks per item and, for a show with no location even then,
  falls back to where its episodes actually are.
  """
  @callback item_path(config, rating_key :: String.t(), kind :: :show | :movie) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Fetches a poster (or any image key Plex reported) as bytes.

  Goes through the server's transcoder for a bounded size, since the raw
  poster is often a megabyte and the dashboard shows it at a few hundred
  pixels. The token stays server-side: the browser only ever sees our own
  cached copy, never a Plex URL with a token in it.
  """
  @callback fetch_image(config, key :: String.t(), opts :: keyword()) ::
              {:ok, {content_type :: String.t(), binary()}} | {:error, term()}

  @doc "The configured implementation. Tests set :plex_client to the Mox mock."
  def impl, do: Application.get_env(:fanfarr, :plex_client, Fanfarr.Plex.HTTPClient)
end
