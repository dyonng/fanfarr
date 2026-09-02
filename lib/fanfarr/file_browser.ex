defmodule Fanfarr.FileBrowser do
  @moduledoc """
  Directory listing for the root-folder picker, in the Sonarr sense: browse
  the container's filesystem to the mount you mean, rather than typing a path
  and finding out on the first write that it was wrong.

  Directories only, hidden entries skipped, sorted case-insensitively. A path
  that cannot be read returns an error rather than an empty list, because
  "empty" and "not allowed to look" call for different fixes.
  """

  @type entry :: %{name: String.t(), path: String.t()}

  @spec list(String.t()) ::
          {:ok, %{path: String.t(), parent: String.t() | nil, dirs: [entry()]}} | {:error, term()}
  def list(path) when is_binary(path) do
    path = normalize(path)

    with {:ok, %{type: :directory}} <- File.stat(path),
         {:ok, names} <- File.ls(path) do
      dirs =
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&%{name: &1, path: Path.join(path, &1)})
        |> Enum.filter(&File.dir?(&1.path))
        |> Enum.sort_by(&String.downcase(&1.name))

      {:ok, %{path: path, parent: parent(path), dirs: dirs}}
    else
      {:ok, _not_a_dir} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parent("/"), do: nil
  defp parent(path), do: Path.dirname(path)

  defp normalize(""), do: "/"

  defp normalize(path) do
    path = Path.expand(path)
    if path == "", do: "/", else: path
  end
end
