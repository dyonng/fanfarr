# Fanfarr 🎺

Theme music management for Plex, in the *arr family. Fanfarr finds the shows
and movies in your library that have no theme music, resolves themes from
[ThemerrDB](https://github.com/LizardByte/ThemerrDB), and applies them — with
an *arr-style dashboard, a real job queue, and an append-only record of
everything it does to your server.

Successor in spirit to LizardByte's Themerr-plex, which ended with Plex's
plugin framework. Fanfarr is a standalone service: no plugin, no Plex Pass
required.

![Library](docs/img/library.png)

<details>
<summary>More screenshots</summary>

**Item page** — status, ThemerrDB result, YouTube search, and the append-only
history for this title.

![Item page](docs/img/item.png)

**Settings** — Plex connection, libraries, root folders, path mappings, theme
downloads, and appearance, all in one place.

![Settings](docs/img/settings.png)

</details>

## Features

- **Overview** — coverage per library, what needs attention, the live queue with an ETA, next sync, failing health checks. Every number links to the matching filtered view.
- **Library** — poster, theme status, critic/audience scores on one scale, studio. Filter by status, type, studio or collection; sort any column; search. Local mirror, so it stays fast at thousands of items.
- **Trim what gets written** — waveform editor with fades at both ends and a loop-join preview. Stored as two numbers, so a crop can be widened later.
- **Stock themes vs chosen ones** — Plex's own agent supplies themes too; those are flagged separately so they can be found and replaced.
- **Movies and shows both** — a local `theme.mp3` is the only way a film gets a theme, verified end to end.
- **Find a theme without leaving the page** — search YouTube, preview inline, pick it. Your pick outranks ThemerrDB from then on, or paste a URL.
- **ThemerrDB** — the default source, looked up automatically; misses are cached so nothing is re-requested.
- **Dry run first, by default** — resolves the source and destination, checks the folder is writable, then stops.
- **Bulk actions** — tick rows or select everything matching a filter; one job per item, two downloads at a time, cancellable mid-run.
- **Local `theme.mp3`, never an upload** — written beside the media, so deleting the file undoes it. Plex's upload API cannot be undone.
- **Renames don't fork a row** — items are matched by IMDb/TMDB/TVDB id, keeping the same theme and history; anything Plex has genuinely dropped goes on the next sync.
- **Root folders, like Sonarr** — mount each library location wherever you like and browse to it in Settings; items are found by directory name across the roots, and each root reports whether it is accessible, writable, and how much room is left on the drive.
- **Loudness normalisation** — every written theme lands at one level (-14 LUFS by default, adjustable).
- **System page** — health checks: Plex reachable, yt-dlp present, roots writable, Plex paths resolving, ThemerrDB up, database healthy. A sidebar dot when something needs attention.
- **Log console** — full-page, colour-coded, filterable.
- **Append-only application log** — every attempt recorded permanently; dry runs included, never counted.
- **Activity** — live queue with an ETA, per-job errors and retry, recent failures, and one button to stop all bulk work.
- **Login from the environment** — `AUTH_USERNAME` and `AUTH_PASSWORD`, an optional "remember me" and a local-address bypass. Unset, the dashboard is open, as the *arrs ship.
- **Safe by default** — libraries are opt-in, a written theme is one file you can delete, and posters are proxied so your Plex token never reaches a browser.
- **One container, one volume** — SQLite, secrets generated on first boot, `PUID`/`PGID` respected, port 7373.

## Tech stack

Elixir / [Phoenix LiveView](https://www.phoenixframework.org/) for the whole
UI — no separate frontend build, no API to keep in sync. [Ash
Framework](https://ash-hq.org/) on SQLite for the data layer, [Oban](https://oban.pro/)
for background jobs (sync, lookups, downloads, applies), `yt-dlp` + `ffmpeg`
for search/download/loudness. One Elixir release, one SQLite file.

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

Both set: a login is required, reconciled to match on every start — change
the password by editing compose and restarting, which is also how you recover
a forgotten one. Both unset: authentication is off entirely, the same default
Sonarr and Radarr ship with — reasonable on a trusted LAN, unwise if the port
is exposed, and warned about in the logs on every boot.

"Remember me" keeps a browser signed in for 30 days. Settings also has
"Disable authentication for local addresses" — checked against the actual TCP
connection, not a header, so it cannot be spoofed from outside.

## Development

Elixir 1.19 / OTP 27 (pinned in `.tool-versions`), Phoenix LiveView, Ash on
SQLite, Oban for jobs. `mix setup`, `mix phx.server`, `mix precommit` before
pushing. `AGENTS.md` carries the decision record and is the first thing to
read before changing anything architectural.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md) for what's built, what's next, and known gaps.

## License

TBD.
