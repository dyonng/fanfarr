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

Built: resource model, auth, dashboard (Library with posters and bulk actions /
Item with YouTube search, inline preview and manual picks / Activity / Settings
with a folder browser / System with health checks), sync + ThemerrDB workers,
Plex HTTP client (**read** paths verified against PMS 1.43.4 and pinned as
captured-response tests; **write** paths -- `upload_theme`, `lock_theme` -- are
unused and unverified), theme origin detection, yt-dlp download and search,
EXDEV-safe writer, ApplyTheme worker (dry run default, local theme.mp3 only,
movies refused), poster cache, health monitor.

**Plex JSON gotcha:** `/themes` returns `<Track>` in XML but a `"Metadata"`
array in JSON, and `selected` is a boolean there, not `"1"`. Plex does honour
`Accept: application/json`. Set `config :fanfarr, req_options: [plug: ...]` to
serve captured responses through the real client in tests.

**Reference coverage:** Movies 0/1785, TV 396/742, Sets 0/37. Movies at zero is
correct -- Plex's movie agent supplies no themes at all.

**Precedence when applying:** URL passed with the job > `manual_theme_url` on
the item > ThemerrDB entry. Oban uniqueness is per item *and* dry-run flag;
with only the item as key, a queued dry run swallowed the apply after it.

Not built yet, in intended order:
1. **Movies.** Verify on the real server whether Plex reads a local theme.mp3
   for a movie. Until then `ApplyTheme` refuses `:movie` items. Do not guess.
2. `/photo/:/transcode` is what the poster cache asks Plex for; verified in use
   only once the operator sees posters. Falls back to the raw thumb key.
3. Codec detection/transcoding (Opus vs Apple TV). Everything is MP3 today.
4. Per-season themes: Plex has none. Documented as not applicable in README.

## Testing notes

- `Fanfarr.DataCase` for domain tests, `FanfarrWeb.ConnCase` +
  `register_and_log_in_user` for authenticated LiveView tests.
- Oban is in `testing: :manual` mode in test; call `Worker.perform/1` directly
  with string-keyed args (see workers/sync_test.exs `stringify/1`).
- Give LiveView forms an `id` or LiveViewTest warns about crash recovery.
