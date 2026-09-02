defmodule Fanfarr.Library.RootFolders do
  @moduledoc """
  Resolves where a theme should actually be written, given the path Plex reports.

  Plex reports the path it reads from. On a pooled filesystem that is the pool
  path -- `/media/merged-storage/TV/One Piece (1999)` -- and writing there is
  correct: the file appears at that path for anything reading the pool, Plex
  included. What the pool decides is which underlying disk physically holds the
  bytes, and under a non-path-preserving create policy that is usually not the
  disk holding the show.

  Configuring the underlying drives as root folders, the way Sonarr and Radarr
  do, lets us bypass the pool and write to the real drive instead. That keeps a
  theme on the same disk as its episodes, and makes the temp-file rename atomic
  again, since source and destination are then on one filesystem.

  Root folders are optional. With none configured, the reported path is used
  as-is and the pool decides placement.

  ## Nesting

  A title is not always a direct child of its library folder. Collections get
  grouped -- `Movies/Harry Potter/<film>` -- and matching only the item's own
  directory name against each root finds nothing for those. Longer tails of the
  reported path are tried in turn, shortest first, so a grouped title resolves
  to `<root>/Harry Potter/<film>` without the operator having to configure the
  grouping folder as a root of its own.

  ## Ambiguity

  A show can exist on more than one branch of a pool -- the directory is created
  wherever a new episode happens to land -- so a single show may match several
  root folders. The tie is broken in this order:

  1. A root that already holds a `theme.mp3` for the item, so an update lands on
     the existing file rather than creating a second one on another disk.
  2. The root holding the most files for the item, which is where the bulk of
     the show lives.
  3. Failing both, the best candidate is still returned, but reported as
     ambiguous so the dashboard can say so rather than choosing silently.
  """

  @theme_filename "theme.mp3"

  # How many trailing path segments to try when matching a reported directory
  # against a root. One is the common case; more covers a library that groups
  # titles, like Movies/Harry Potter/<film>.
  @max_depth 4

  @type root :: String.t()
  @type resolution ::
          {:ok, String.t(), :reported | :root_folder | :ambiguous}
          | {:error, :not_found}

  @doc """
  Resolves the directory to write a theme into.

  `reported_dir` is the item's directory in *our* view of the filesystem -- run
  the path Plex gave us through `Fanfarr.PathMapping` first.

  Returns the directory and how it was decided:

    * `:reported` -- used as given, either because no roots are configured or
      because the path already lives under one.
    * `:root_folder` -- a pool path resolved to exactly one underlying root.
    * `:ambiguous` -- several roots hold this item and the tiebreaks did not
      separate them. A directory is still returned.
  """
  @spec resolve(String.t(), [root()]) :: resolution()
  def resolve(reported_dir, roots)

  def resolve(reported_dir, []) when is_binary(reported_dir) do
    {:ok, normalize(reported_dir), :reported}
  end

  def resolve(reported_dir, roots) when is_binary(reported_dir) and is_list(roots) do
    dir = normalize(reported_dir)

    if under_any_root?(dir, roots) do
      # Already a specific location rather than a pool path -- nothing to resolve.
      {:ok, dir, :reported}
    else
      case candidates(dir, roots) do
        [] -> {:error, :not_found}
        [only] -> {:ok, only, :root_folder}
        many -> disambiguate(many)
      end
    end
  end

  @doc """
  The root folders that contain this item.

  Exposed so the dashboard can show a genuinely split item rather than only the
  directory that won.
  """
  @spec candidates(String.t(), [root()]) :: [String.t()]
  def candidates(reported_dir, roots) do
    # A pool presents the same relative structure as its branches, so an item
    # sits at the same place under the pool and under the drive holding it.
    #
    # How much of that structure to reuse is the question. Matching only the
    # last segment assumes every title is a direct child of a root, which a
    # library that groups them is not: a film at
    # .../Movies/Harry Potter/<film> has no <root>/<film> to find, and the
    # whole item was reported unresolvable. So progressively longer tails are
    # tried and the shortest that exists wins. Shortest rather than longest so
    # that an item resolving today keeps resolving to the same place: one
    # segment is what was tried before, and a deeper tail is only consulted
    # when that finds nothing. The cost is that a same-named directory sitting
    # directly under another root would win over the grouped one, which is a
    # collision we have not seen and would rather have than a silent change to
    # where existing items are written.
    segments = reported_dir |> normalize() |> Path.split() |> Enum.reject(&(&1 == "/"))
    roots = Enum.map(roots, &normalize/1)

    1..min(@max_depth, length(segments))//1
    |> Enum.map(fn depth ->
      tail = segments |> Enum.take(-depth) |> Path.join()

      roots
      |> Enum.map(&Path.join(&1, tail))
      |> Enum.filter(&File.dir?/1)
    end)
    |> Enum.find([], &(&1 != []))
  end

  defp disambiguate(dirs) do
    case Enum.filter(dirs, &File.regular?(Path.join(&1, @theme_filename))) do
      [one] ->
        {:ok, one, :root_folder}

      _ ->
        ranked = Enum.sort_by(dirs, &file_count/1, :desc)
        best = hd(ranked)
        runner_up = Enum.at(ranked, 1)

        # A clear winner on file count is a decision; a tie is not.
        if runner_up && file_count(best) == file_count(runner_up) do
          {:ok, best, :ambiguous}
        else
          {:ok, best, :root_folder}
        end
    end
  end

  defp file_count(dir) do
    case File.ls(dir) do
      {:ok, entries} -> length(entries)
      {:error, _} -> 0
    end
  end

  defp under_any_root?(dir, roots) do
    Enum.any?(roots, fn root ->
      root = normalize(root)
      dir == root or String.starts_with?(dir, root <> "/")
    end)
  end

  defp normalize("/"), do: "/"
  defp normalize(path), do: String.replace_trailing(path, "/", "")
end
