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
bypass), dashboard (Library with posters, scores, studio/collection filters,
sortable columns and bulk actions / Item with YouTube search, inline preview
and manual picks / Activity with an ETA / Settings with a folder browser and
appearance / System with health checks / a full-page log console), sync +
ThemerrDB workers, Plex HTTP client (**read** paths verified against PMS
1.43.4 and pinned as captured-response tests; **write** paths --
`upload_theme`, `lock_theme` -- are unused and unverified), theme origin
detection, yt-dlp download and search, EXDEV-safe writer, ApplyTheme worker
(dry run default, local theme.mp3, **shows and movies both** -- verified on
the reference server, see below), poster cache, health monitor.

**Plex JSON gotcha:** `/themes` returns `<Track>` in XML but a `"Metadata"`
array in JSON, and `selected` is a boolean there, not `"1"`. Plex does honour
`Accept: application/json`. Set `config :fanfarr, req_options: [plug: ...]` to
serve captured responses through the real client in tests.

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
the item > ThemerrDB entry. Oban uniqueness is per item *and* dry-run flag;
with only the item as key, a queued dry run swallowed the apply after it.

**Loudness:** downloads are normalised to -14 LUFS by default via ffmpeg
`loudnorm` two-pass (`theme_loudness_lufs` to change it). Measure any file with
`Fanfarr.Themes.Normalizer.measure/1` to calibrate against themes already in
the library rather than guessing.

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
