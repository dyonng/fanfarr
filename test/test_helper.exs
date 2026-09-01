ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Fanfarr.Repo, :manual)

# The Plex client is a behaviour precisely so tests never need a server.
Mox.defmock(Fanfarr.PlexClientMock, for: Fanfarr.Plex.Client)
Application.put_env(:fanfarr, :plex_client, Fanfarr.PlexClientMock)
