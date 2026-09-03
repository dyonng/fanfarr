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

- **Library dashboard** — every show and movie with its poster and theme
  status: missing, Plex default, Fanfarr-applied, local file, or failed. Filter
  by status, type, and library; search; served from a local mirror, so it
  stays fast at thousands of items.
- **Knows a stock theme from a chosen one** — Plex marks its own agent's
  themes in the `ratingKey`, and Fanfarr reads it. A show that "has a theme"
  because Plex shipped one is listed as such, so it can be found and replaced.
- **Find a theme without leaving the page** — search YouTube from the item
  page, play the result inline, and pick it. What you pick is exactly what
  gets applied, and it outranks ThemerrDB from then on. Or paste a URL.
- **ThemerrDB** — the community theme database is looked up automatically as
  the default source; misses are cached so nothing is re-requested.
- **Dry run first, by default** — a preview resolves the source and the
  destination and checks the folder is writable, then stops. Run it on the
  whole library before writing a single file.
- **Bulk actions** — tick rows, or select everything matching a filter, and
  preview, look up, or apply in one go.
- **Local `theme.mp3`, never an upload** — themes are written beside the
  media, where deleting the file undoes them. Plex's upload API cannot be
  undone, so it is not used.
- **mergerfs-aware writes** — files are staged in the destination folder and
  renamed, with a copy fallback when the pool puts the temp file on another
  branch (`EXDEV`). No half-written theme is ever visible to a Plex scan.
- **Root folders, like Sonarr** — mount each library location wherever you
  like (`/tv1`, `/tv2`, …), browse to it from Settings, and items are located
  by directory name across the roots so a theme lands on the drive that holds
  the show.
- **System page** — Sonarr-style health checks: Plex reachable, yt-dlp
  present, root folders writable, Plex paths resolving on this side of the
  mount, ThemerrDB up, database healthy. A dot on the sidebar when something
  needs attention. Version and build on the same page for bug reports.
- **Append-only application log** — every attempt Fanfarr makes is recorded
  permanently: what, when, from where, and how it went. Dry runs included,
  but never counted.
- **Activity view** — live job queue with per-job errors and retry, plus
  recent theme failures with their actual error message.
- **Login from the environment** — set `AUTH_USERNAME` and `AUTH_PASSWORD` in
  compose and that is the account. No sign-up page, no reset flow. Leave them
  unset and the dashboard is open, as the *arrs also start.
- **Safe by default** — libraries are opt-in, dry-run is the default, sync
  never re-enables what you disabled, and posters are cached server-side so
  your Plex token never reaches a browser.
- **One container, one volume** — SQLite for everything, secrets generated on
  first boot, `PUID`/`PGID` respected, port 7373.

### Not there yet

- **Movies.** Plex's movie agent supplies no themes at all, so movies are the
  bigger half of the job — but whether Plex reads a local `theme.mp3` for a
  movie is unverified, and the alternative (uploading through the API) cannot
  be undone. Applying to movies is disabled until that is tested on a real
  server. Previews and manual picks work.
- **Per-season themes.** Plex has no per-season theme; a theme belongs to the
  show. Nothing to build there.
- **Codec handling.** Opus does not play on Apple TV; everything is written as
  MP3 for now, which plays everywhere.

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

"Remember me for 30 days" on the sign-in form skips the password on that
browser until whichever comes first: signing out, changing the password (which
revokes every session and remember-me token at once), or the 30 days running
out.

## Development

Elixir 1.19 / OTP 27 (pinned in `.tool-versions`), Phoenix LiveView, Ash on
SQLite, Oban for jobs. `mix setup`, `mix phx.server`, `mix precommit` before
pushing. `AGENTS.md` carries the decision record and is the first thing to
read before changing anything architectural.

## License

TBD.
