defmodule Fanfarr.Plex.HTTPClient do
  @moduledoc """
  The real Plex Media Server client, over its HTTP API.

  Plex answers in JSON when asked with an Accept header, which spares us its
  XML. Confirmed against Plex Media Server 1.43.4: a request carrying
  `Accept: application/json` comes back as JSON.

  **The JSON key is not the XML element name.** `/themes` returns `<Track>`
  elements in XML but a `"Metadata"` array in JSON, and `selected` is a real
  boolean there rather than `"1"`. Read paths are verified against a live
  server; `upload_theme/3` and `lock_theme/3` are still unexercised, and every
  parse tolerates missing fields rather than crashing on a server that reports
  less.

  `includeGuids=1` is load-bearing on the listing call: without it Plex omits
  the per-provider Guid entries, and those IDs are how ThemerrDB is keyed.
  `includeCollections=1` is the same bargain for Collection tags, and costs
  the same nothing -- both ride a request the sync already makes.
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
    query = "includeGuids=1&includeCollections=1"

    with {:ok, body} <- get(config, "/library/sections/#{section_key}/all?#{query}") do
      items =
        body
        |> containers(["Directory", "Video", "Metadata"])
        |> Enum.map(&parse_item/1)

      {:ok, items}
    end
  end

  @impl true
  def collections(config, section_key) do
    with {:ok, body} <- get(config, "/library/sections/#{section_key}/collections") do
      collections =
        body
        |> containers(["Directory", "Metadata"])
        |> Enum.map(&%{rating_key: to_string(&1["ratingKey"]), title: presence(&1["title"])})
        |> Enum.reject(&(is_nil(&1.title) or &1.rating_key == ""))

      {:ok, collections}
    end
  end

  @impl true
  def collection_items(config, collection_rating_key) do
    with {:ok, body} <- get(config, "/library/metadata/#{collection_rating_key}/children") do
      keys =
        body
        |> containers(["Directory", "Video", "Metadata"])
        |> Enum.map(&to_string(&1["ratingKey"]))
        |> Enum.reject(&(&1 == "" or &1 == "nil"))

      {:ok, keys}
    end
  end

  @impl true
  def themes(config, rating_key) do
    with {:ok, body} <- get(config, "/library/metadata/#{rating_key}/themes") do
      themes =
        body
        |> containers(["Photo", "Track", "Metadata"])
        |> Enum.map(fn t ->
          rating_key = t["ratingKey"] && to_string(t["ratingKey"])

          %{
            rating_key: rating_key,
            key: t["key"],
            selected: t["selected"] in [true, 1, "1"],
            # Plex sends no `provider`; the ratingKey scheme carries it.
            origin: Fanfarr.Plex.ThemeOrigin.classify(rating_key),
            agent: Fanfarr.Plex.ThemeOrigin.agent(rating_key)
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

  @impl true
  def select_theme(config, rating_key, theme_rating_key) do
    put(
      config,
      "/library/metadata/#{rating_key}/theme?url=#{URI.encode_www_form(theme_rating_key)}"
    )
  end

  @impl true
  def refresh_metadata(config, rating_key) do
    put(config, "/library/metadata/#{rating_key}/refresh")
  end

  # A partial scan: Plex walks just this directory rather than the whole
  # section. Deliberately not `refresh?force=1` on the item, which would also
  # re-run the metadata agents and can overwrite unlocked fields the operator
  # edited by hand. Making the scanner look at one folder is the narrowest
  # thing that gets a new theme.mp3 seen.
  @impl true
  def scan_directory(config, section_key, path) do
    get_ok(config, "/library/sections/#{section_key}/refresh?path=#{URI.encode_www_form(path)}")
  end

  @impl true
  def raw(config, path) do
    get(config, path)
  end

  @impl true
  def metadata(config, rating_key) do
    with {:ok, body} <- get(config, "/library/metadata/#{rating_key}") do
      case containers(body, ["Directory", "Video", "Metadata"]) do
        [item | _] -> {:ok, item}
        [] -> {:error, :not_found}
      end
    end
  end

  @impl true
  def item_path(config, rating_key, kind) do
    with {:ok, item} <- metadata(config, rating_key) do
      case item_path(item) do
        path when is_binary(path) and path != "" -> {:ok, path}
        _ -> from_episodes(config, rating_key, kind)
      end
    end
  end

  # Last resort for a show: ask for one episode and take the directory its file
  # sits in. Plex nests Show/Season/Episode.mkv by convention but not by rule,
  # so a directory that looks like a season folder is stepped over and anything
  # else is taken as the show folder. A heuristic, and the only thing left when
  # the server reports no location at all.
  defp from_episodes(config, rating_key, :show) do
    path =
      "/library/metadata/#{rating_key}/allLeaves?X-Plex-Container-Start=0&X-Plex-Container-Size=1"

    with {:ok, body} <- get(config, path) do
      file =
        body
        |> containers(["Video", "Metadata"])
        |> Enum.flat_map(&Map.get(&1, "Media", []))
        |> Enum.flat_map(&Map.get(&1, "Part", []))
        |> Enum.find_value(& &1["file"])

      case file do
        nil -> {:error, :no_path_reported}
        file -> {:ok, file |> Path.dirname() |> strip_season_dir()}
      end
    end
  end

  defp from_episodes(_config, _rating_key, _kind), do: {:error, :no_path_reported}

  @season_dir ~r/^(season\b|specials$|s\d+$)/i

  defp strip_season_dir(dir) do
    if Regex.match?(@season_dir, Path.basename(dir)), do: Path.dirname(dir), else: dir
  end

  @impl true
  def fetch_image(config, key, opts \\ []) do
    width = Keyword.get(opts, :width, 300)
    height = Keyword.get(opts, :height, 450)

    # /photo/:/transcode is what every Plex client uses for scaled artwork.
    # If it is ever refused, the raw key is a fine fallback -- bigger, but
    # still the right picture.
    transcode =
      "/photo/:/transcode?" <>
        URI.encode_query(%{
          "width" => width,
          "height" => height,
          "minSize" => 1,
          "upscale" => 1,
          "url" => key
        })

    case get_binary(config, transcode) do
      {:ok, _} = ok -> ok
      {:error, _} -> get_binary(config, key)
    end
  end

  defp get_binary(config, path) do
    req = build(config, path: path) |> Req.merge(headers: [{"Accept", "image/*"}])

    case Req.get(req, url: path) do
      {:ok, %{status: status, body: body, headers: headers}}
      when status in 200..299 and is_binary(body) ->
        type =
          case Map.get(headers, "content-type") do
            [t | _] -> t |> String.split(";") |> hd() |> String.trim()
            _ -> "image/jpeg"
          end

        if String.starts_with?(type, "image/"),
          do: {:ok, {type, body}},
          else: {:error, {:not_an_image, type}}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      # Plex explains itself in the body, and throwing that away turned a 500
      # into a number with no next step. Kept short: it is a header line or an
      # HTML error page, and only the beginning of either says anything.
      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, detail(body)}}

      {:error, reason} ->
        {:error, reason}
    end
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
      # The external scores an agent fetched, and only those. Plex's
      # `userRating` -- the operator's own stars on a title -- is deliberately
      # not read: it says how one person felt rather than how the thing was
      # received, and it would be the only column meaning something different
      # per install.
      #
      # Absent for plenty of items -- an agent with no opinion, a library Plex
      # has not enriched -- so these are read if they are there and left nil if
      # they are not. Nothing downstream treats nil as an error; the library
      # table shows an empty cell.
      critic_score: number(m["rating"]),
      critic_score_source: Fanfarr.Library.Score.provider(m["ratingImage"]),
      audience_score: number(m["audienceRating"]),
      audience_score_source: Fanfarr.Library.Score.provider(m["audienceRatingImage"]),
      # One string, and it is whichever studio the agent decided to name --
      # often the distributor rather than the production company, so it groups
      # a library usefully without being an authority on who made anything.
      studio: presence(m["studio"]),
      # Collections are the curated answer to the same question, and unlike
      # studio there can be several. Absent unless includeCollections=1, and
      # absent anyway for a library nobody has organised.
      collections: tags(m["Collection"]),
      added_at: unix(m["addedAt"])
    }
  end

  # Sent as JSON numbers, but a string costs nothing to accept and a malformed
  # rating is not worth failing a whole library sync over.
  defp number(value) when is_number(value), do: value / 1

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp number(_), do: nil

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

  # Plex's tag arrays are [%{"tag" => "..."}, ...]. Anything else -- the key
  # absent, a server that does not honour includeCollections -- is no tags,
  # which is also the honest answer for an unorganised library.
  defp tags(list) when is_list(list) do
    list
    |> Enum.map(&presence(&1["tag"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp tags(_), do: []

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  defp containers(body, names) when is_list(names) do
    container = body["MediaContainer"] || %{}
    Enum.flat_map(names, &Map.get(container, &1, []))
  end

  defp containers(body, name), do: containers(body, [name])

  # --- transport -------------------------------------------------------------

  defp get(config, path), do: request(config, :get, path, nil)

  # Plex answers a partial scan with an empty 200, which is not JSON. Ask for
  # it as a GET but keep only the status.
  defp get_ok(config, path) do
    case request(config, :get, path, nil) do
      {:ok, _body} -> :ok
      other -> other
    end
  end

  defp post(config, path, data), do: request(config, :post, path, data)
  defp put(config, path), do: request(config, :put, path, nil)

  defp request(config, method, path, data) do
    req = build(config, [])

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

  defp detail(body) when is_binary(body) do
    body |> String.trim() |> String.slice(0, 300)
  end

  defp detail(body) when is_map(body) or is_list(body), do: inspect(body, limit: 20)
  defp detail(_), do: ""

  defp build(%{base_url: base_url, token: token} = config, _opts) do
    [
      base_url: base_url,
      headers: [{"X-Plex-Token", token}, {"Accept", "application/json"}],
      retry: :transient,
      max_retries: 2,
      receive_timeout: 30_000
    ]
    # Background workers can afford retries and a long wait; an interactive
    # connection test cannot -- the LiveView client abandons a push after
    # 30s and remounts the page, which reads as a mysterious reload. Callers
    # pass tighter options through the config map for that case.
    |> Keyword.merge(Map.get(config, :req_options, []))
    # Lets the test suite serve captured real responses through this exact
    # function, rather than testing a parser that production does not call.
    |> Keyword.merge(Application.get_env(:fanfarr, :req_options, []))
    |> Req.new()
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
