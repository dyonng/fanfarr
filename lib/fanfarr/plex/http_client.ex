defmodule Fanfarr.Plex.HTTPClient do
  @moduledoc """
  The real Plex Media Server client, over its HTTP API.

  Plex answers in JSON when asked with an Accept header, which spares us its
  XML. Endpoint shapes follow what python-plexapi uses, since that is the
  implementation the old plugin ecosystem proved out -- but they are treated as
  unverified until exercised against a live server (phase 1), and every parse
  tolerates missing fields rather than crashing on a server that reports less.

  `includeGuids=1` is load-bearing on the listing call: without it Plex omits
  the per-provider Guid entries, and those IDs are how ThemerrDB is keyed.
  """
  @behaviour Fanfarr.Plex.Client

  @impl true
  def server_info(config) do
    with {:ok, body} <- get(config, "/") do
      root = body["MediaContainer"] || %{}
      {:ok, %{name: root["friendlyName"] || "Plex", version: root["version"] || "unknown"}}
    end
  end

  @impl true
  def sections(config) do
    with {:ok, body} <- get(config, "/library/sections") do
      sections =
        body
        |> containers("Directory")
        |> Enum.filter(&(&1["type"] in ["show", "movie"]))
        |> Enum.map(fn dir ->
          %{
            key: to_string(dir["key"]),
            title: dir["title"],
            kind: kind(dir["type"]),
            locations:
              dir |> Map.get("Location", []) |> Enum.map(& &1["path"]) |> Enum.reject(&is_nil/1)
          }
        end)

      {:ok, sections}
    end
  end

  @impl true
  def items(config, section_key) do
    with {:ok, body} <- get(config, "/library/sections/#{section_key}/all?includeGuids=1") do
      items =
        body
        |> containers(["Directory", "Video", "Metadata"])
        |> Enum.map(&parse_item/1)

      {:ok, items}
    end
  end

  @impl true
  def themes(config, rating_key) do
    with {:ok, body} <- get(config, "/library/metadata/#{rating_key}/themes") do
      themes =
        body
        |> containers(["Photo", "Track", "Metadata"])
        |> Enum.map(fn t ->
          %{
            rating_key: t["ratingKey"] && to_string(t["ratingKey"]),
            key: t["key"],
            selected: t["selected"] in [true, 1, "1"],
            provider: t["provider"]
          }
        end)

      {:ok, themes}
    end
  end

  @impl true
  def upload_theme(config, rating_key, {:url, url}) do
    post(config, "/library/metadata/#{rating_key}/themes?url=#{URI.encode_www_form(url)}", nil)
  end

  def upload_theme(config, rating_key, {:file, path}) do
    case File.read(path) do
      {:ok, data} -> post(config, "/library/metadata/#{rating_key}/themes", data)
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  @impl true
  def lock_theme(config, rating_key, library_type_id) do
    # Field locking goes through the section-edit endpoint, the same call the
    # web UI makes. type is Plex's numeric metadata type (2 = show, 1 = movie).
    path =
      "/library/metadata/#{rating_key}?" <>
        URI.encode_query(%{"theme.locked" => "1", "type" => library_type_id})

    put(config, path)
  end

  # --- parsing ---------------------------------------------------------------

  defp parse_item(m) do
    guids = Map.get(m, "Guid", [])

    %{
      rating_key: to_string(m["ratingKey"]),
      title: m["title"],
      year: m["year"],
      kind: kind(m["type"]),
      guid: m["guid"],
      imdb_id: guid_id(guids, "imdb"),
      tmdb_id: guid_id(guids, "tmdb"),
      tvdb_id: guid_id(guids, "tvdb"),
      path: item_path(m),
      thumb: m["thumb"],
      theme: m["theme"],
      added_at: unix(m["addedAt"])
    }
  end

  # Shows carry Location; movies carry a file inside Media/Part, whose
  # directory is what a theme.mp3 sits beside.
  defp item_path(%{"Location" => [%{"path" => path} | _]}), do: path

  defp item_path(%{"Media" => media}) when is_list(media) do
    media
    |> Enum.flat_map(&Map.get(&1, "Part", []))
    |> Enum.find_value(fn part ->
      case part["file"] do
        nil -> nil
        file -> Path.dirname(file)
      end
    end)
  end

  defp item_path(_), do: nil

  defp guid_id(guids, provider) do
    prefix = provider <> "://"

    Enum.find_value(guids, fn %{"id" => id} ->
      if is_binary(id) and String.starts_with?(id, prefix) do
        String.replace_prefix(id, prefix, "")
      end
    end)
  end

  defp kind("show"), do: :show
  defp kind("movie"), do: :movie
  defp kind(_), do: :movie

  defp unix(nil), do: nil
  defp unix(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp unix(_), do: nil

  defp containers(body, names) when is_list(names) do
    container = body["MediaContainer"] || %{}
    Enum.flat_map(names, &Map.get(container, &1, []))
  end

  defp containers(body, name), do: containers(body, [name])

  # --- transport -------------------------------------------------------------

  defp get(config, path), do: request(config, :get, path, nil)
  defp post(config, path, data), do: request(config, :post, path, data)
  defp put(config, path), do: request(config, :put, path, nil)

  defp request(%{base_url: base_url, token: token}, method, path, data) do
    req =
      Req.new(
        base_url: base_url,
        headers: [{"X-Plex-Token", token}, {"Accept", "application/json"}],
        retry: :transient,
        max_retries: 2,
        receive_timeout: 30_000
      )

    result =
      case method do
        :get -> Req.get(req, url: path)
        :post -> Req.post(req, url: path, body: data || "")
        :put -> Req.put(req, url: path)
      end

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if method == :get, do: {:ok, ensure_map(body)}, else: :ok

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_map(body) when is_map(body), do: body

  defp ensure_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp ensure_map(_), do: %{}
end
