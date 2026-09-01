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

  @doc "The configured implementation. Tests set :plex_client to the Mox mock."
  def impl, do: Application.get_env(:fanfarr, :plex_client, Fanfarr.Plex.HTTPClient)
end
