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
- **Dark is the default theme** (`root.html.heex` falls back to "dark", not
  "system") because the product sits beside Sonarr and Radarr.

## Current state / not yet built

Built: resource model, auth, dashboard (Library / Item / Activity / Settings),
sync + ThemerrDB workers, Plex HTTP client (UNVERIFIED against a real server).

Not built yet, in intended order:
1. Phase-1 verification of the Plex client against the real server
   (`scripts/plex-theme-survey.sh` output pending from the operator).
2. yt-dlp resolver + theme file writer (EXDEV fallback REQUIRED -- reference
   host pools use category.create=mfs; see AGENTS.md).
3. ApplyTheme worker: intent -> resolve -> upload/local-write -> outcome, with
   dry-run default ON.
4. Poster caching (never hotlink 2,550 thumbs from Plex).
5. Health checks panel; codec detection/transcoding (Opus vs Apple TV);
   season themes research.

## Testing notes

- `Fanfarr.DataCase` for domain tests, `FanfarrWeb.ConnCase` +
  `register_and_log_in_user` for authenticated LiveView tests.
- Oban is in `testing: :manual` mode in test; call `Worker.perform/1` directly
  with string-keyed args (see workers/sync_test.exs `stringify/1`).
- Give LiveView forms an `id` or LiveViewTest warns about crash recovery.
