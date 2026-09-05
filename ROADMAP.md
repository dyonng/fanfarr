# Roadmap

What's built, what's next, and known gaps — kept short on purpose. For the
day-to-day decision record, see `AGENTS.md`.

## Built

- Library dashboard: posters, theme status, critic/audience scores (normalised
  to one scale), studio, collections, sortable/filterable columns, filters
  preserved when you open an item and come back.
- Item page: ThemerrDB lookup, inline YouTube search/preview, manual pick,
  append-only history, "Remove theme."
- Sync: Plex sections and items, theme origin detection (stock vs chosen),
  rename-aware (re-keys the same row rather than forking it), removes items
  Plex has genuinely dropped.
- Apply pipeline: dry run by default, local `theme.mp3` for shows **and
  movies**, loudness normalisation, mergerfs-safe writes (EXDEV fallback),
  bulk actions with a stoppable queue and an ETA.
- Settings: Plex connection + test, per-library enable, scheduling (sync and
  ThemerrDB intervals, 0 to turn either off), root folders with a folder
  browser, path mappings, theme downloads (how many at once, yt-dlp proxy,
  loudness target), appearance, authentication (env-based login, remember me,
  local-address bypass).
- Scheduling that the operator owns: one cron heartbeat every five minutes
  decides what is due, so intervals are editable without a restart and a
  manual run resets the clock. See `Fanfarr.Scheduling`.
- System page: health checks (Plex, yt-dlp, root folders, path resolution,
  ThemerrDB, database), diagnostics tools, bug-report bundle.
- Full-page log console: colour-coded, filterable, separate from System, and
  persisted -- the last 5,000 lines (configurable) survive a restart, with a
  Clear button.
- Auth: env-var login only, no sign-up/reset/mailer; optional and off by
  default, matching the *arr stack.

## Known gaps

- **No real JSON API.** `AshJsonApi.Domain` is wired into the domains and
  `/api/json` is routed, but no resource declares a `json_api do` block, so
  there are zero actual routes today — it's inert scaffolding. Worth building
  out if a companion app or automation ever needs one; otherwise worth
  removing rather than leaving as a half-finished promise.
- **Jellyfin.** `Fanfarr.Plex.Client` is a behaviour specifically so a second
  implementation is possible, but nothing above it has been exercised against
  anything but Plex.
- **Codec handling.** Everything is written as MP3. Fine today; would matter
  if a source ever yielded Opus, which does not play on Apple TV.
- **No notifications.** No webhook/Discord/etc. on sync completion or apply
  failure — Activity and the sidebar badge are the only signal right now.
- **No per-library or per-item exclude list.** An enabled library syncs
  everything in it; there's no way to skip a title without removing the whole
  library.
- **Single operator account.** One username/password pair, not a user list —
  fine for a homelab, not for a household with separate logins.
- **No import of a previous Themerr-plex state.** Anyone migrating starts
  from a fresh sync; local `theme.mp3` files already on disk are picked up
  the next time a section syncs, but the application log starts empty.

## Not planned

- **Per-season themes.** Plex has no per-season theme; a theme belongs to the
  show, so there's nothing to build here.
- **Undoing a Plex API upload.** Plex's own API has no delete for an uploaded
  theme; that's exactly why Fanfarr writes a local file instead. Documented,
  not a bug.
