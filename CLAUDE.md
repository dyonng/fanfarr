# CLAUDE.md — session notes for Fanfarr

Read `AGENTS.md` first: it holds the decision record, the non-negotiables,
the verified facts about the reference deployment, and the AshSqlite
limitations found so far. This file is the shorter operational memory.

## Toolchain in a fresh session

Elixir is not preinstalled in CI sandboxes. Install from hexpm's precompiled
builds (versions pinned in `.tool-versions`):

    curl -fsSL https://builds.hex.pm/builds/otp/amd64/ubuntu-24.04/OTP-27.3.4.16.tar.gz | tar -xz -C /opt/erlang --strip-components=1
    (cd /opt/erlang && ./Install -minimal /opt/erlang)
    curl -fsSL https://builds.hex.pm/builds/elixir/v1.19.6-otp-27.zip -o /tmp/ex.zip && unzip /tmp/ex.zip -d /opt/elixir
    export PATH=/opt/erlang/bin:/opt/elixir/bin:$PATH LANG=C.UTF-8 LC_ALL=C.UTF-8 ELIXIR_ERL_OPTIONS="+fnu"
    mix local.hex --force && mix local.rebar --force

Always `mix precommit` before pushing, and check its REAL exit code --
`mix precommit | tail` gates on tail's exit and once let a failing suite
through.

## Architecture quick map

- `Fanfarr.Library` / `Fanfarr.Themes` / `Fanfarr.Settings` / `Fanfarr.Accounts`
  -- Ash domains; call them through their code interfaces
  (`Fanfarr.Library.list_media_items!()`), never raw `Ash.read` from web code.
- `Fanfarr.Plex.Client` -- behaviour; `Fanfarr.Plex.HTTPClient` is real,
  `Fanfarr.PlexClientMock` (Mox) is wired in test_helper.exs. Everything above
  the behaviour is media-server-agnostic on purpose (Jellyfin later).
- `Fanfarr.Config` -- setting override, then env var, then nil. Settings rows
  exist only when an operator overrode something.
- Workers (`Fanfarr.Workers.*`): SyncLibrary fans out SyncSection per enabled
  section; RefreshThemerr fans out LookupTheme per item. Queues: sync: 3,
  themerrdb: 2 (deliberately narrow -- community service).
- Web: LiveView only. Auth via ash_authentication (password strategy only; no
  mailer, no confirmation, no magic link -- all stripped, see router comments).
  Registration closes after the first user
  (`Accounts.User.Validations.OnlyFirstUser`).
- Routes: `/` is the Overview dashboard, `/library` the table, `/library/:id`
  an item. The library was the homepage until v0.1.52.
- **Authentication is declared in the router**, once, on the
  `ash_authentication_live_session` block -- not per LiveView. It used to be
  per module, and adding a page without remembering the `on_mount` line left
  it readable with no session. `dashboard_test.exs` enumerates every
  authenticated path; add new ones there.

## Decisions that answer recurring questions

- **No ash_typescript**: there is no TypeScript frontend to type. LiveView
  carries the UI; the only JS is the vendored SaladUI runtime. Revisit only if
  a real TS client (mobile app, external SPA) appears -- then generate types
  from the domains rather than hand-writing them.
- **Mocking**: Mox, against the `Fanfarr.Plex.Client` behaviour. Ash and
  Phoenix ship no mock library; Mox is the ecosystem standard.
- **Authentication**: credentials come from `AUTH_USERNAME`/`AUTH_PASSWORD`,
  reconciled at boot by `Fanfarr.Accounts.Seed`. No sign-up route, no reset
  flow, no mailer. Both unset means no account, which means no login -- the
  dashboard is open, as the *arrs start, warned loudly in logs.
  `Fanfarr.Accounts.AuthMode.required?/0` derives the mode from whether a user
  exists, so it cannot disagree with what the sign-in form would do.
  The identity field is `username`, not email.
- **`HashPasswordChange` needs `strategy_name`** when used in an action the
  password strategy did not generate. Without it, it raises at *runtime*, not
  compile time -- which is how a broken `:set_password` shipped once.
- **Secrets**: SECRET_KEY_BASE and TOKEN_SIGNING_SECRET both auto-generate on
  first boot and persist under /config. Env vars win if set.
- **Icons: Lucide**, not Heroicons. The components are shadcn's and Lucide is
  the set they are drawn against. Delivered the same way the generator
  delivered Heroicons: a sparse git dep (`deps/lucide/icons`) plus a Tailwind
  plugin (`assets/vendor/lucide.js`) emitting one CSS mask per referenced icon.
  `mask-size: contain` is load-bearing -- Lucide draws on a 24px grid and is
  clipped in a `size-4` box without it. Names drift between Lucide releases
  (`help-circle` is now `circle-question-mark`); `test/icons_test.exs` fails on
  a name with no SVG, because Tailwind emits nothing and the icon silently
  disappears.
- **Authentication is optional.** No `AUTH_USERNAME`/`AUTH_PASSWORD` means no
  account, which means no login: dashboard pages render for anyone and
  `/sign-in` redirects to `/` rather than presenting a form for credentials
  that do not exist.
- **Dark is the default theme** (`root.html.heex` falls back to "dark", not
  "system") because the product sits beside Sonarr and Radarr.

## Current state / not yet built

`ROADMAP.md` is the up-to-date, user-facing list of what's built and what
isn't -- read that first. What follows here is implementation detail that
doesn't belong in a roadmap.

Built: resource model, auth (env-based login, remember-me, local-address
bypass), pages (Overview dashboard at `/` -- coverage, needs-attention,
queue, schedule, failing health checks, all from `Fanfarr.Overview` /
Library with posters, scores, studio/collection filters,
sortable columns and bulk actions / Item with YouTube search, inline preview
and manual picks / Activity with an ETA / Settings with a folder browser and
appearance / System with health checks / a full-page log console), sync +
ThemerrDB workers, Plex HTTP client (**read** paths verified against PMS
1.43.4 and pinned as captured-response tests; **write** paths --
`upload_theme`, `lock_theme` -- are unused and unverified), theme origin
detection, yt-dlp download and search, EXDEV-safe writer, ApplyTheme worker
(local theme.mp3, **shows and movies both** -- verified on the reference
server, see below), poster cache, health monitor.

**Never bump the version by hand.** `docker.yml` bumps the patch in `mix.exs`
and commits it as `chore: vX.Y.Z` on every push to main, before the build, so
the image is tagged with the version it reports. A manual bump races that job
and only adds a commit to rebase over -- so the version a change ships as is
the bot's next one, not whatever is in `mix.exs` when it is pushed.

**Plex JSON gotcha:** `/themes` returns `<Track>` in XML but a `"Metadata"`
array in JSON, and `selected` is a boolean there, not `"1"`. Plex does honour
`Accept: application/json`. Set `config :fanfarr, req_options: [plug: ...]` to
serve captured responses through the real client in tests.

**A section's listing is not only its titles.** `/library/sections/{key}/all`
returns the section's *collections* alongside its films, as entries of type
`"collection"`. `kind/1` answers `nil` for anything that is not `movie` or
`show` and `items/2` drops those -- it used to default to `:movie`, which put
"Aquaman Collection" in the library as a film that could never have a theme,
so it sat permanently under the missing filter. `sections/1` had always
filtered on type; the listing never got the same guard. No migration is needed
for installs that stored them: `prune/2` deletes whatever the listing stops
mentioning.

**Movies were the last big unverified piece and are done.** Plex's movie
agent supplies no themes at all, so a local `theme.mp3` was the only possible
path, and whether Plex would even read one was open until it was tried on the
reference server -- it worked first try. `ApplyTheme` no longer refuses
`:movie` items. If you find a reference to movies being refused or unverified
elsewhere (AGENTS.md has some older passages), that text is stale, not the
behavior.

**Renamed items don't fork a row.** Plex issues a new ratingKey on a folder
rename rather than updating the item in place, which an earlier version of
sync treated as a straightforward delete-and-recreate -- losing the
operator's chosen theme and the application log. Sync now pairs a departing
item with an arriving one sharing the same imdb/tmdb/tvdb id and re-keys the
existing row; only what's left unpaired is actually deleted (which cascades
its history, deliberately -- see `Fanfarr.Library.MediaItem`'s destroy
action). See `Fanfarr.Workers.SyncSection` for the pairing logic and its
ambiguity rules.

**Studio and collections** come from the same Plex listing request
(`includeCollections=1` alongside `includeGuids=1`) plus, for collections, a
second pass against `/library/sections/<key>/collections` -- the per-item
Collection tags alone miss agent-built collections (Star Wars, Dune, that
sort), only reporting the operator's hand-made ones. See
`Fanfarr.Workers.SyncSection.collections/3`.

**Scheduling is not a crontab.** Oban reads its crontab once at boot and OSS
Oban has no dynamic cron, so a schedule the operator can edit cannot be a
crontab entry. One entry (`*/5`) runs `Fanfarr.Workers.Scheduler`, which asks
`Fanfarr.Scheduling` what is due. Intervals live in Settings; `0` is off. The
"last run" clock is written by the *workers* at the top of `perform/1`, not by
the heartbeat -- that is what makes a manual sync reset the interval, and what
stops an unconfigured install re-queueing a doomed sync every five minutes.
The heartbeat is excluded from `Jobs.summary/0` and `Jobs.recent/1` unless it
failed; 288 rows a day would bury the work it exists to start. Adding a second
crontab entry is a regression -- `test/fanfarr/schedule_test.exs` fails if you
do.

**The apply queue's width is the operator's, the others are not.**
`Fanfarr.Jobs.apply_concurrency/0` resolves setting -> env -> compiled default,
clamped to 1..10; `put_apply_concurrency/1` persists *and* calls
`Oban.scale_queue/2` so it takes effect on work already queued.
`Fanfarr.Jobs.oban_config/0` is what `application.ex` hands the supervisor, so
a restart picks the saved value back up. :themerrdb stays at 2 deliberately --
that is a community-run host, not a throughput knob.

**The log is persisted, and nothing on that path may log.**
`Fanfarr.Log.Buffer` still holds the last 400 entries in memory (the
bug-report bundle reads that, because diagnostics for a broken database
should not need the database), and now forwards each redacted entry to
`Fanfarr.Log.Store`, which batches them into `log_entries` once a second and
trims to a retention setting (default 5,000, `LOG_RETENTION_ENTRIES`; the
Logs page has a Clear button).

Every repo call in that module passes `log: false`, and the retention lives
in process state rather than being read per flush. This is not tidiness:
Ecto logs every query, the buffer captures that line, and the buffer feeds
the store -- so one logged query guarantees the next flush has work, forever,
filling the log with the log writing the log. Same rule as
`Fanfarr.Diagnostics.Redactor`, and it has its own tests ("not feeding
itself" in `test/fanfarr/log/store_test.exs`). SQLite's LIKE also needs
`ESCAPE` named explicitly, or a search for "100%" matches everything.

**Boot migrations run on a single connection**, not the application's normal
pool. `Ecto.Migrator`'s own child spec migrates on the already-started pool,
and SQLite's per-connection schema cache means two migrations touching one
table in one boot can land on different connections and the second one fails
with "no such column" on a fresh database. See `Fanfarr.Repo.Migrator`. If
you add a migration and CI's Docker smoke test fails with a missing-column
error on a fresh DB, this is almost certainly not it (the fix already
handles it) -- look at the migration itself first.

**Reference coverage (as last verified):** Movies applying works end to end;
TV 396/742 themed at last survey.

**Precedence when applying:** URL passed with the job > `manual_theme_url` on
the item > ThemerrDB entry. Oban uniqueness is per item *and* theme URL; with
only the item as key, auditioning a second video within the five-minute window
is silently dropped as a duplicate of the first. There is no dry run -- it was
removed in v0.1.51 along with its column, and its rows were deleted, because
every query over that table had to remember to exclude them.

**Running the suite needs ffmpeg and ffprobe.** The cutter, waveform, source
cache and apply tests shell out to the real binaries rather than stubbing
them -- a stub would have happily agreed that a silent file was correct. CI
installs ffmpeg for the same reason.

**Trimming:** the crop is `theme_start_ms`/`theme_end_ms` on the item, never a
second audio file -- the mp3 is derived output, so a crop is two more
parameters on the recipe and can be *widened* later. Pipeline order is
download -> **cut** -> normalise -> place, and that order is load-bearing:
normalisation is two-pass, so cutting afterwards leaves the surviving segment
at whatever level it happened to be. `Fanfarr.Themes.Cutter` uses
`atrim`+`asetpts` rather than `-ss`/`-to`, because output-side seeking does not
rebase timestamps before the filter graph and `afade` then silences the whole
file. `set_manual_theme` clears the crop: it belongs to the audio it was
measured against.

**Trim source ladder** (`Fanfarr.Themes.EditSource`): cached original ->
the written mp3 when the last apply had no crop (derived from the application
log, not a stored flag) -> fresh download. A *cropped* mp3 can never seed an
edit; that audio is gone. `Fanfarr.Themes.SourceCache` keeps the untranscoded
stream (YouTube is lossy already; WAV would be bigger and no better), keyed on
a hash of the URL, kinds `:source` and `:render`, age limit plus an LRU byte
cap. Populated on the edit path only -- a bulk apply must never fill it.

**The trim editor is modelled on Audacity**, which settles most of its
questions. A ruler strip carries the two edge grips, so they are not overlays
lying across the waveform -- as overlays they were 40px wide and full height,
which made every click within 20px of an edge grab a handle, and since an
untrimmed selection parks the edges at 0 and the duration, the ends of a track
could not be reached at all. On the waveform itself the gesture is decided by
proximity at pointerdown: within 6px of an edge (10 for a coarse pointer)
drags that edge, a press that moves drags out a new selection, and a press
that does not move seeks -- *including* one inside a grab zone, so there is no
dead zone anywhere. Shift-click extends the nearer edge. Space plays or stops,
Home plays from the selection start, `[` and `]` set in and out at the
playhead.

Repeat is a flag and is drawn as a switch; "Hear the loop" and "Select the
whole track" are actions and are drawn as buttons. These were previously one
toggle called "Loop the join", which meant both "repeat" and "start playback
three seconds before the out point" -- so with it on, which was the default,
there was no way to hear the selection from its beginning. The out point is
enforced from `requestAnimationFrame`, not `timeupdate`: that fires ~4x a
second, so a loop overshot by up to 250ms.

**Loudness:** downloads are normalised to -14 LUFS by default via ffmpeg
`loudnorm` two-pass (`theme_loudness_lufs` to change it). Measure any file with
`Fanfarr.Themes.Normalizer.measure/1` to calibrate against themes already in
the library rather than guessing.

**Activity retention is a count, not an age.** `Fanfarr.Jobs.prune_history!/0`
runs on the scheduler heartbeat and keeps the newest N finished jobs, N being
the `activity_history` setting (default 1000). Two rules, because the job table
holds two populations: the rows Activity lists get N, and the scheduler
heartbeats -- invisible unless they fail, 288 a day -- get a separate hard cap,
or they would be most of the table within a week while contributing nothing to
the page the limit is about. Nothing unfinished is ever deleted. Oban's own
`pruner` is by age and cannot express this, so it sits at 365 days as a distant
backstop; at its old one day it actively deleted rows the setting promised to
keep.

**Every timestamp shown is the appliance's local time** -- `Fanfarr.Clock`,
`TZ` from the compose file, rendered server-side. One server answers one way,
so a phone, a laptop and a TV browser agree; browser-side localisation was
tried first and meant a laptop that travelled disagreed with the box in the
basement about when a sync ran.

No timezone library: `:calendar.universal_time_to_local_time/1` goes through
the C library, so it is the same conversion `date` does and DST is free
(measured UTC-4 in September, UTC-5 in January for America/Toronto). Two
things follow. **The BEAM reads `TZ` once, at VM start** -- neither
`System.put_env/2` nor `:os.putenv/2` moves it afterwards, so changing the
zone needs a container restart, and `clock_test.exs` runs its zone cases in a
subprocess. And **the zoneinfo files have to be in the image**: `debian:*-slim`
omits them and glibc answers an unresolvable `TZ` with UTC and no error, so the
Dockerfile installs `tzdata` and `Clock.log_zone/0` logs the resolved zone at
boot, where a zone that did not take reads as `UTC` beside a `TZ` that says
otherwise.

**Debugging:** the System page has a redacted log view and diagnostics tools
(environment, item trace, yt-dlp video check, raw Plex probe, and a one-click
bug-report bundle), plus a full-page, colour-coded log console at `/logs`.
`Fanfarr.Diagnostics.Redactor` must never query the database -- see AGENTS.md
for why that would loop forever.

See `ROADMAP.md` for what's next.

## Testing notes

- `Fanfarr.DataCase` for domain tests, `FanfarrWeb.ConnCase` +
  `register_and_log_in_user` for authenticated LiveView tests.
- Oban is in `testing: :manual` mode in test; call `Worker.perform/1` directly
  with string-keyed args (see workers/sync_test.exs `stringify/1`).
- Give LiveView forms an `id` or LiveViewTest warns about crash recovery.
