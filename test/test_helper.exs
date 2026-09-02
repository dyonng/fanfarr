# Some tests mount a tmpfs to get a real cross-filesystem rename (EXDEV) or a
# genuinely read-only directory. Both need privileges CI does not have, so the
# capability is probed once here and the tag excluded when it is missing.
#
# This is a tag rather than a skip from inside `setup`: a setup callback may
# only return :ok, a keyword or a map, and returning {:skip, reason} raises --
# which is how these tests "skipped" in CI for four runs while passing locally
# as root.
can_mount? =
  (fn ->
     dir =
       Path.join(System.tmp_dir!(), "fanfarr-mount-probe-#{System.unique_integer([:positive])}")

     File.mkdir_p!(dir)

     try do
       case System.cmd("mount", ["-t", "tmpfs", "-o", "size=1m", "tmpfs", dir],
              stderr_to_stdout: true
            ) do
         {_, 0} ->
           System.cmd("umount", [dir], stderr_to_stdout: true)
           true

         _ ->
           false
       end
     rescue
       # No mount binary at all.
       _ -> false
     after
       File.rm_rf(dir)
     end
   end).()

# Loudness normalisation shells out to ffmpeg. It ships in the image, but a
# development machine may not have it, and a test that silently passes without
# it would prove nothing about the thing it claims to test.
has_ffmpeg? =
  try do
    match?({_, 0}, System.cmd("ffmpeg", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

excluded =
  [] ++
    if(can_mount?, do: [], else: [:requires_mount]) ++
    if has_ffmpeg?, do: [], else: [:requires_ffmpeg]

ExUnit.start(exclude: excluded)

unless has_ffmpeg? do
  IO.puts("\n[fanfarr] Skipping tests tagged :requires_ffmpeg -- ffmpeg is not installed here.")
end

unless can_mount? do
  IO.puts("""
  \n[fanfarr] Skipping tests tagged :requires_mount -- this environment cannot \
  mount a tmpfs, so the real EXDEV and read-only cases cannot be exercised here. \
  They run where privileges allow.
  """)
end

Ecto.Adapters.SQL.Sandbox.mode(Fanfarr.Repo, :manual)

# The Plex client is a behaviour precisely so tests never need a server.
Mox.defmock(Fanfarr.PlexClientMock, for: Fanfarr.Plex.Client)
Application.put_env(:fanfarr, :plex_client, Fanfarr.PlexClientMock)

# The downloader is a behaviour for the same reason: the suite must never reach
# YouTube, and yt-dlp is not installed in CI.
Mox.defmock(Fanfarr.ThemeDownloaderMock, for: Fanfarr.Themes.Downloader)
Application.put_env(:fanfarr, :theme_downloader, Fanfarr.ThemeDownloaderMock)
