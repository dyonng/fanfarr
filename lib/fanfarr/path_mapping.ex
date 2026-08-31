defmodule Fanfarr.PathMapping do
  @moduledoc """
  Translates the filesystem paths Plex reports into paths this container can see.

  Plex tells us where a show lives using *its own* view of the filesystem. When
  Fanfarr writes a `theme.mp3` next to the media, it needs the same file in
  *our* view. If both containers mount the library at the same path -- the
  recommended arrangement -- the two are identical and no translation happens.
  When they differ, this maps between them, the same job Sonarr and Radarr do
  with remote path mapping.

  Mappings are `plex_prefix -> local_prefix` pairs. The longest matching prefix
  wins, so a general rule and a specific exception can coexist:

      /data          -> /media
      /data/anime    -> /mnt/anime-ssd

  A path under `/data/anime` takes the second rule; everything else under
  `/data` takes the first.

  Matching is on path segments, not characters, so `/data/tv` never matches
  `/data/tv-4k`.
  """

  @type mapping :: {String.t(), String.t()}

  @doc """
  Parses mappings from their configuration string form.

  Pairs are `plex_prefix:local_prefix`, separated by `;` or newlines. Blank
  entries are ignored so a multi-line env var can be laid out readably.

      iex> Fanfarr.PathMapping.parse("/data:/media; /data/anime:/mnt/anime")
      [{"/data/anime", "/mnt/anime"}, {"/data", "/media"}]

  Returns pairs ordered longest-prefix-first, which is the order `to_local/2`
  needs, so callers can parse once and reuse.
  """
  @spec parse(String.t() | nil) :: [mapping()]
  def parse(nil), do: []
  def parse(""), do: []

  def parse(string) when is_binary(string) do
    string
    |> String.split([";", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_pair/1)
    |> sort_by_specificity()
  end

  defp parse_pair(entry) do
    case String.split(entry, ":", parts: 2) do
      [from, to] ->
        from = from |> String.trim() |> normalize()
        to = to |> String.trim() |> normalize()

        if from == "" or to == "", do: [], else: [{from, to}]

      _ ->
        []
    end
  end

  # Longest first, so the most specific rule is tried before a general one that
  # would also match.
  defp sort_by_specificity(mappings) do
    Enum.sort_by(mappings, fn {from, _} -> -String.length(from) end)
  end

  @doc """
  Translates a Plex-reported path into a local one.

  With no mappings, or when nothing matches, the path is returned unchanged --
  the common case is that both containers see the library identically, and a
  missing mapping should not mangle a path that was already correct. Whether
  the result actually exists is a separate question, answered by `resolvable?/1`.

      iex> mappings = Fanfarr.PathMapping.parse("/data:/media")
      iex> Fanfarr.PathMapping.to_local("/data/tv/One Piece (1999)", mappings)
      "/media/tv/One Piece (1999)"
  """
  @spec to_local(String.t(), [mapping()]) :: String.t()
  def to_local(path, mappings) when is_binary(path) do
    normalized = normalize(path)

    Enum.find_value(mappings, path, fn {from, to} ->
      if under?(normalized, from) do
        to <> binary_part(normalized, byte_size(from), byte_size(normalized) - byte_size(from))
      end
    end)
  end

  # A path is under a prefix only on a segment boundary: "/data/tv" is under
  # "/data", but "/data-old/tv" is not, and neither is "/datastore".
  defp under?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  @doc """
  Whether a translated path exists and is a directory we can read.

  This is what turns a silent no-op into a diagnosable one: a library whose
  root does not resolve means the mapping is wrong or the volume is not
  mounted, and the dashboard should say so rather than reporting zero work.
  """
  @spec resolvable?(String.t()) :: boolean()
  def resolvable?(path) when is_binary(path), do: File.dir?(path)

  # Strips trailing slashes so "/data/" and "/data" behave identically, while
  # leaving a bare "/" intact.
  defp normalize("/"), do: "/"

  defp normalize(path) when is_binary(path) do
    String.replace_trailing(path, "/", "")
  end
end
