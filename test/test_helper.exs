ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Fanfarr.Repo, :manual)

# The Plex client is a behaviour precisely so tests never need a server.
Mox.defmock(Fanfarr.PlexClientMock, for: Fanfarr.Plex.Client)
Application.put_env(:fanfarr, :plex_client, Fanfarr.PlexClientMock)

# The downloader is a behaviour for the same reason: the suite must never reach
# YouTube, and yt-dlp is not installed in CI.
Mox.defmock(Fanfarr.ThemeDownloaderMock, for: Fanfarr.Themes.Downloader)
Application.put_env(:fanfarr, :theme_downloader, Fanfarr.ThemeDownloaderMock)
