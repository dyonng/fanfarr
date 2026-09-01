# Fanfarr 🎺

Theme music management for Plex, in the *arr family. Fanfarr finds the shows
and movies in your library that have no theme music, resolves themes from
[ThemerrDB](https://github.com/LizardByte/ThemerrDB), and applies them — with
an *arr-style dashboard, a real job queue, and an append-only record of
everything it does to your server.

Successor in spirit to LizardByte's Themerr-plex, which ended with Plex's
plugin framework. Fanfarr is a standalone service: no plugin, no Plex Pass
required for the local-file output path.

## Features

- **Library dashboard** — every show and movie with its theme status: missing,
  Plex-supplied, Fanfarr-applied, local file, or failed. Filter by status,
  type, and library; search; served from a local mirror, so it stays fast at
  thousands of items.
- **Honest status taxonomy** — status is derived from facts (what Plex
  reports, what exists on disk, what the application log says), never stored,
  so it cannot drift.
- **Append-only application log** — Plex has no API to delete an uploaded
  theme, so every attempt Fanfarr makes is recorded permanently: what, when,
  from where, and how it went. Dry runs included, but never counted.
- **Activity view** — live job queue with per-job errors and retry, plus
  recent theme failures with their actual error message.
- **Root folders, like Sonarr** — mount each library location wherever you
  like (`/tv1`, `/tv2`, …); items are located by directory name across the
  configured roots. On mergerfs and friends, themes are written to the drive
  that actually holds the show.
- **Login from the environment** — set `AUTH_USERNAME` and `AUTH_PASSWORD` in
  compose and that is the account. No sign-up page, no reset flow: changing or
  recovering the password is an edit and a restart. Leave them unset and the
  dashboard is open, as the *arrs also start.
- **Safe by default** — libraries are opt-in, dry-run is the default for bulk
  work, and sync never re-enables what you disabled.
- **One container, one volume** — SQLite for everything, secrets generated on
  first boot, `PUID`/`PGID` respected, port 7373.

### Not built yet

Theme resolution (yt-dlp) and application are in progress — the pipeline that
turns a ThemerrDB entry into audio on your server. Codec handling (Opus will
not play on Apple TV), poster caching, health checks, and per-season theme
research are planned; see `AGENTS.md` for the roadmap and the reasoning.

## Running it

```yaml
services:
  fanfarr:
    image: ghcr.io/dyonng/fanfarr:latest
    container_name: fanfarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Toronto
    volumes:
      - ./appdata:/config
      # One mount per library location, exactly as Sonarr does it. Register
      # these paths as Root Folders in Settings.
      - /path/to/tv-drive-1:/tv1
      - /path/to/movie-drive-1:/movies1
    ports:
      - 7373:7373/tcp
    restart: unless-stopped
```

Open `http://<host>:7373`, create the operator account, set the Plex URL and
token under Settings, enable the libraries you want managed, and Sync.

See `docs/deployment.md` for path mapping, mergerfs specifics (`:rslave`,
create policies, `EXDEV`), reverse proxies, and why yt-dlp should not go
through your VPN.

## Authentication

```yaml
environment:
  - AUTH_USERNAME=admin
  - AUTH_PASSWORD=something-long-and-random
```

Both set: a login is required, and the account is reconciled to match on every
start. Change the password by editing compose and restarting — which is also
how you recover a forgotten one. Renaming `AUTH_USERNAME` removes the old
account rather than leaving a second login behind.

Both unset: authentication is off entirely. Every page is reachable without
signing in and the sign-in route redirects to the dashboard, since there are
no credentials to enter. This is the same default Sonarr and Radarr ship with
-- reasonable on a trusted LAN, unwise if the port is exposed -- and it is
warned about in the logs on every boot.

## Development

Elixir 1.19 / OTP 27 (pinned in `.tool-versions`), Phoenix LiveView, Ash on
SQLite, Oban for jobs. `mix setup`, `mix phx.server`, `mix precommit` before
pushing. `AGENTS.md` carries the decision record and is the first thing to
read before changing anything architectural.

## License

TBD.
