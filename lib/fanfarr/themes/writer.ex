defmodule Fanfarr.Themes.Writer do
  @moduledoc """
  Putting a finished audio file at its destination without leaving a partial
  one behind.

  ## Why this is not `File.cp/2`

  A copy straight onto the destination path is visible to Plex while it is
  still being written. Plex scans on its own schedule, and a half-written
  theme.mp3 is a theme.mp3 as far as it is concerned. So the file is written
  under a temporary name in the *destination directory* and then renamed,
  which is atomic within a filesystem.

  ## Why the rename can fail, on this deployment specifically

  The reference host pools five drives with mergerfs under
  `category.create=mfs`, which is **not** path-preserving: a newly created
  file goes to whichever branch has the most free space, which is routinely
  not the branch holding the rest of the show. A rename between two branches
  is a rename across filesystems, and the kernel answers `EXDEV`.

  So `EXDEV` is the expected case here, not an exotic one, and the fallback
  is copy-then-unlink. That is not atomic, so the copy still goes to a
  temporary name first and only the final rename is racy -- and on the branch
  where the copy landed, that rename is within one filesystem again.
  """

  require Logger

  @doc """
  Moves `source` to `destination`, replacing whatever is there.

  `source` is consumed on success. The destination directory must exist.
  """
  @spec place(Path.t(), Path.t()) :: :ok | {:error, term()}
  def place(source, destination) do
    tmp = temp_name(destination)

    with :ok <- stage(source, tmp),
         :ok <- promote(tmp, destination) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # Get the bytes next to the destination, by whichever route works.
  defp stage(source, tmp) do
    case File.rename(source, tmp) do
      :ok ->
        :ok

      {:error, :exdev} ->
        # Expected on a mergerfs pool; see the moduledoc.
        with :ok <- copy(source, tmp) do
          # Only unlink the source once the copy is durably in place, so a
          # failure here loses a temp file rather than the download.
          _ = File.rm(source)
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy(source, tmp) do
    case File.cp(source, tmp) do
      :ok -> fsync(tmp)
      {:error, reason} -> {:error, reason}
    end
  end

  # Without this the rename can be durable while the contents are not, which
  # after a power cut leaves a correctly named empty file -- worse than a
  # missing one, because nothing will retry it.
  defp fsync(path) do
    case File.open(path, [:read, :write, :raw]) do
      {:ok, fd} ->
        result = :file.sync(fd)
        File.close(fd)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp promote(tmp, destination) do
    case File.rename(tmp, destination) do
      :ok ->
        :ok

      {:error, :exdev} ->
        # The temp file is in the destination's own directory, so this should
        # not happen. It can if the pool moves a branch underneath us; fall
        # back rather than fail a download that already succeeded.
        Logger.warning(
          "[fanfarr] rename within #{Path.dirname(destination)} crossed a filesystem; copying"
        )

        with :ok <- copy(tmp, destination) do
          _ = File.rm(tmp)
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Hidden and suffixed so a scanner that walks the directory mid-write does
  # not mistake it for media, and unique so two runs cannot collide.
  defp temp_name(destination) do
    Path.join(
      Path.dirname(destination),
      ".fanfarr-#{:erlang.unique_integer([:positive])}.part"
    )
  end
end
