# Fanfarr

Self-hosted service that manages theme music for a Plex library, with an
*arr-style web dashboard. Successor in spirit to LizardByte's Themerr-plex,
which died with Plex's plugin framework.

**This top section is the decision record. Read it before changing anything
architectural. Everything below "Phoenix/Elixir guidelines" is generated
framework boilerplate.**

---

## Non-negotiables

These come from the project brief and are not open for re-litigation.

1. **Theme uploads are irreversible through Plex's API.** `deleteTheme()` raises
   `NotImplementedError`. Every upload is append-only, so: be idempotent (check
   before uploading, never blind-upload on a scan cycle), and dry-run must exist
   from the start and default **on**.
2. **Never hold a database transaction open across an HTTP call.** SQLite has a
   single writer; a yt-dlp fetch or Plex upload takes minutes and would block
   every other write. Write intent, commit, do the IO, write the outcome.
3. **Do not build a Plex plugin.** The framework is gone.
4. **Do not manage posters, artwork or collections.** Kometa owns that lane.
5. **Do not bundle or redistribute theme audio.** Resolve and apply only.
6. **Keep the Plex client behind an interface.** Jellyfin is out of scope for
   v1 but must not be made impossible.

## Stack, and why

| Choice | Reason |
|---|---|
| Elixir + Ash + SQLite | One container, no external services, real concurrency for scan/resolve/upload fan-out |
| Phoenix LiveView | Deletes the SPA layer entirely; the live Activity/job view is near-free |
| Oban with `Engines.Lite` + `Notifiers.PG` | Job queue in the same SQLite file; no Postgres LISTEN/NOTIFY needed |
| SaladUI, **vendored** into `lib/fanfarr_web/components/vendor` | shadcn/ui is React and cannot run under LiveView. The hex package declares `igniter`/`sourceror` as runtime deps, which would pollute the release; the components themselves never reference them |
| daisyUI **removed** | Phoenix ships it by default, but its themes and shadcn's CSS variables define overlapping tokens and fight; shadcn is also closer to *arr chrome |
| yt-dlp as a standalone binary | YouTube breaks it often; its version must move independently of ours |

Single user. No authentication framework needed. Outside contributors are not
a goal, so Elixir's smaller talent pool is an accepted cost.

## The reference deployment (verified, not assumed)

Host `serve-the-dy`, Ubuntu 24.04.

- **Plex runs on BARE METAL**, not in a container. It therefore reports *host*
  paths. This is the single most consequential fact about this deployment.
- Five ext4 drives under `/media`, pooled by **mergerfs 2.42.0** into
  `/media/merged-storage/{TV,Movies,Music,Sets}`.
- Pool options: `defaults,nonempty,allow_other,use_ino,category.create=mfs,minfreespace=20G`
- **`category.create=mfs` is NOT path-preserving.** Given the spread of free
  space, new files land on whichever drive has most room -- usually not the one
  holding the show.
- Sonarr and Radarr write to the individual drives (`/tv1`..`/tv5`,
  `/movies1`..`/movies5`); Plex reads the pool. Both describe the same files.
- Everything owned `1000:1000` (dyonng). TZ `America/Toronto`.
- Docker network `vpn_network`. Config convention `/home/dyonng/docker/<app>:/config`.
- Library size: ~1,800 movies, ~750 series. **Zero** existing `theme.mp3` files.
- Sections, as surveyed: `1` Movies (movie), `2` TV Shows (show), `3` Sets
  (movie), `5` Music (artist, correctly ignored -- we filter to show/movie).
- **"Sets" is 37 concert/DJ recordings with scene-release filenames**
  (`Anyma.Coachella.2026...VP9-sidmonster`). It is typed `movie` and will sync,
  but nothing in it will ever match ThemerrDB. Per-library enable/disable is
  what saves the operator here; sections default to disabled already.

## Theme coverage, surveyed 2026-09-01

| Section | Items | With theme | Coverage |
|---|---|---|---|
| Movies | 1785 | 0 | **0%** |
| TV Shows | 742 | 396 | 53% |
| Sets | 37 | 0 | 0% |

**Movies being flat zero is correct, not a bug in the survey.** Plex's movie
agent supplies no themes at all; only the TV agent does. That gap is the entire
reason Themerr-plex existed and is the bulk of Fanfarr's job: 1,785 movies from
nothing, plus 346 shows.

**Movies read a local `theme.mp3`. Verified on the reference server**, first
try, once the pipeline stopped refusing them. Plex's movie agent supplies no
themes of its own, but Local Media Assets picks up a local one for a movie
exactly as it does for a show, so no upload path is needed. `upload_theme/3`
and `lock_theme/3` remain in the client, still unexercised.

They were refused for a while on the grounds that this was unverified. It was
-- and refusing was a way of never finding out.

One thing movies do need that shows do not: **a folder of their own.** A show's
path is a directory by construction, but a movie's is derived from its media
file, so a film sitting loose among others resolves to the shared folder, where
a `theme.mp3` would attach to every neighbouring film. `destination_dir/1`
refuses that case.

## Deployment decisions

**Mounts follow *arr convention: one numbered mount per library location.**
`/tv1`, `/tv2`, `/movies1`... exactly as Sonarr and Radarr do it. This is a
product decision, not a technical one -- Fanfarr is named to sit in the *arr
stack and should feel native in it. Users get one mount per location and full
control over container paths.

A previous revision of this file recommended a single `/media:/media` mount.
That was wrong for this project. It works, and it is still the zero-config
shortcut, but it is not the documented shape.

**Root folders are how items are located.** Resolution matches an item by its
**directory name** across the configured root folders -- it does not need the
library mounted at Plex's own path, and it does not need to be told which drive
holds which show. This is why numbered mounts are fine: an earlier claim that
they "would break Fanfarr" was incorrect.

Root folders also decide *placement*: writing to a resolved drive rather than
through the pool keeps a theme on the same disk as its episodes and makes the
temp-file rename atomic.

**`PATH_MAPPINGS`** translates Plex-reported prefixes to container paths, for
cases root folders alone cannot cover. Longest prefix wins; matching is on
segment boundaries so `/data/tv` never matches `/data/tv-4k`.

**`:rslave` is required on any mount that contains other mounts** -- a mergerfs
pool, or a directory with drives underneath. Without it the container sees an
empty directory where the nested mount should be, with **no error**. This is
the single most confusing failure mode in this deployment.

**`EXDEV` handling is mandatory, not defensive.** Under `mfs` the temp file and
its target routinely land on different drives, so `rename` fails. The writer
must fall back to copy-then-unlink.

**yt-dlp does not go through the VPN by default.** YouTube bot-checks
datacenter addresses far harder than residential ones, and the cookie-file
fallback is *worse* over a VPN (reads as account compromise). `YTDLP_PROXY`
exists as the opt-in escape hatch.

## Design decisions in the code

- **Theme status is a calculation, never a stored column.** The five states
  (missing / failed / local file / Fanfarr-applied / Plex-supplied) are
  conclusions drawn from facts already held. A stored status would be a sixth
  fact that eventually disagrees with the other five.
- **Sections default to disabled.** A newly discovered Plex library is opt-in,
  because uploads cannot be undone.
- **Sync never re-enables what an operator disabled** -- `enabled` is not in the
  accepted fields of `sync_from_plex`.
- **The ThemerrDB cache persists `youtube_theme_edited`.** It is a change key: if
  it has not moved, nothing needs re-resolving regardless of TTL. Upstream
  ignores this field; it is the backbone of the health/drift feature.
- **The health endpoint is deliberately shallow** -- app up, database reachable.
  Plex or YouTube being down belongs in the dashboard, not in a check that
  restarts the container.

## ThemerrDB

```
https://app.lizardbyte.dev/ThemerrDB/{movies|tv_shows}/{imdb|themoviedb}/{id}.json
```

Response is a **full TMDB metadata object** (~32-38 keys) with five
`youtube_theme_*` fields grafted on. 3-23 KB each. **No bulk endpoint is
known**, so a cold sync of this library is ~2,550 requests. Cache aggressively,
cache 404s too. Details in `docs/themerrdb.md`.

## What Plex reports about a theme (verified 2026-09-01)

`/library/metadata/<id>/themes` returns `<Track>` elements. Verbatim:

    <Track key="/library/metadata/45870/file?url=metadata%3A%2F%2Fthemes%2F..."
           ratingKey="metadata://themes/tv.plex.agents.series_b00837223037c5e21ab3a908018b4aed41791a2f"
           selected="1" />

- **There is no `provider` attribute.** Do not add code that reads one; a
  previous version did and it was silently always `nil`.
- **Origin lives in the `ratingKey`'s URI scheme**, the same convention Plex
  uses for posters and art:
  - `metadata://themes/<agent-id>_<sha>` -- supplied by that agent. VERIFIED.
  - `upload://themes/<sha>` -- uploaded via the API. **INFERRED** from the
    poster/art convention; we have not yet uploaded a theme and read it back.
    Confirm on the first real upload and update `Fanfarr.Plex.ThemeOrigin`.
- `selected="1"` marks the active one; an item may carry several.
- **The JSON key is not the XML element name.** In XML the element is `<Track>`;
  in JSON the array is `"Metadata"`, and `selected` is a real boolean, not `"1"`.
  Anything written by reading the XML output will parse nothing. Confirmed:

      {"MediaContainer":{"size":1,...,"Metadata":[
        {"key":"/library/metadata/45870/file?url=...",
         "ratingKey":"metadata://themes/tv.plex.agents.series_b008...",
         "selected":true}]}}

- **Plex does honour `Accept: application/json`** (PMS 1.43.4.10903). The app
  parses JSON everywhere; this was the last unverified assumption in the read
  path and it holds.
- **The listing's own `theme` attribute does NOT encode origin.** It is
  `theme="/library/metadata/45870/theme/1788156492"` -- a timestamped URL. This
  is why sync makes a second call to `/themes`; there is no shortcut.
- These responses are pinned verbatim in `test/fanfarr/plex/http_client_test.exs`
  and run through the real `HTTPClient` via `Req.Test`, not a parallel parser.
- This is what makes "already has a theme, but it is only Plex's stock one"
  answerable, which was the operator's stated main use case.
- Cost: origin needs one request per item, so sync asks **only about items the
  listing already says have a theme** -- 396 requests, not 2,564.
- Titles come back with XML entities (`9&#189; Weeks`, `Above &amp; Beyond`).
  Irrelevant to the app, which parses JSON, but it bites shell tooling.

## Mistakes already made -- do not repeat

- `.dockerignore` had `/config/`, which collided with Elixir's own `config/`
  directory and stripped it from the build context. `test/dockerfile_context_test.exs`
  guards this now.
- `assets.deploy` ran tailwind before `compile`, but LiveView generates
  colocated CSS *during* compilation. Fixed in `mix.exs`.
- Phoenix generates an IPv6 bind, which dies with `:eafnosupport` wherever IPv6
  is off -- including many Docker daemons. Default is IPv4; `BIND_IPV6=true`
  opts back in.
- `TwMerge.Cache` must be in the supervision tree or every vendored component
  raises on a missing ETS table at render time.
- Advice has flip-flopped on mount layout. It is settled above: *arr-style
  numbered mounts.
- `check_origin` defaulted to Phoenix's behaviour of validating against
  `url: [host:]`, i.e. "localhost". Reaching the server by LAN IP was refused
  at the socket, so pages rendered statically and nothing was interactive
  while the browser retried forever. A LAN appliance has no single legitimate
  origin; it is off by default now, pinnable via `CHECK_ORIGIN`.
- The generated auth pages shipped with the Ash Framework logo, hot-linked
  from ash-hq.org -- wrong branding, and unreachable on an isolated network.
  `FanfarrWeb.AuthOverrides` clears it.
- `Fanfarr.Plex.HTTPClient` was written to read a `provider` field on themes,
  and `MediaItem.plex_theme_provider` carried a confident docstring saying Plex
  "reports 'local' for a theme.mp3 found on disk". Both were invented. Plex
  sends no such field, nothing ever wrote the column, and a test asserted the
  fabricated behaviour. **A plausible-looking field that is always nil fails by
  reading as "no data" rather than as an error.** Replaced by
  `plex_theme_origin`, derived from the ratingKey and pinned to a real sample
  in `test/fanfarr/plex/theme_origin_test.exs`.
- `scripts/plex-theme-survey.sh` grepped `version="[^"]*"` out of raw XML and
  matched the `<?xml version="1.0"?>` declaration, so it reported the server
  version as `1.0` on every run. It also surveyed only the XML API while the
  app parses JSON -- **a diagnostic that exercises a different code path than
  the program is worth very little.** It now probes `Accept: application/json`
  explicitly.
- The favicon 404'd in prod while working in dev. `Plug.Static`'s `:only`
  matches whole path segments, so `favicon.svg` does not match the digested
  `favicon-e922....svg` that the layout actually links to. Directories are
  unaffected (`assets` stays `assets`), which is why only the root-level files
  broke. `:only_matching` is the prefix-based option Plug documents for exactly
  this. **`raise_on_missing_only` cannot catch it: it is enabled only when code
  reloading is, i.e. dev, the one environment with no digests.** Guarded by an
  invariant test in `test/favicon_test.exs` that every bare file in
  `static_paths/0` has a matching prefix.
- A `--` inside an XML comment is illegal, and SVG is XML. A double hyphen in
  an explanatory comment in `favicon.svg` made the whole file unparseable; the
  browser showed a broken-image glyph rather than reporting anything, and the
  generated ICO came out structurally valid and entirely blank. Guarded in
  `test/favicon_test.exs`, and `scripts/generate-icons.py` now counts painted
  pixels and refuses to write a blank icon.
- A module attribute that reads `System.get_env/1` is invisible to Mix's
  recompilation tracking, so `Fanfarr.Version` kept the `BUILD_REF` it was
  first compiled with and reported the wrong build on every later one. Fixed
  with `__mix_recompile__?/0`. **A version that silently lies about which build
  it is, is worse than no version at all.**
- Chromium will not render into a window smaller than roughly 50px and produces
  a valid, empty PNG instead. `generate-icons.py` renders into a 200px window
  and crops.
- Icons are linked at their plain paths with a `?v=` query, never through `~p`,
  which rewrites them to the digested filename. See root.html.heex.
- **`ApplyTheme` checked that the path Plex reported existed inside the
  container, and gave up when it did not.** It usually does not: Plex runs on
  the host and reports host paths (`/media/red-10-redemption/TV/One Pace`),
  while the container mounts the same drives as `/tv1..5`. **Root folders exist
  precisely to bridge that**, so the guard rejected every item the mechanism
  was built for. Resolve first, then check the directory you would actually
  write to -- which is what `Fanfarr.Health.path_resolution/0` had been doing
  correctly all along. The two now share
  `Fanfarr.Workers.ApplyTheme.destination_dir/1`, because a diagnostic that can
  disagree with the code it diagnoses is worse than none.
- **`{:skip, reason}` is not a valid return from an ExUnit `setup` callback.**
  A setup may return only `:ok`, a keyword or a map; anything else raises. Two
  mount-dependent tests "skipped gracefully" in CI for four runs this way --
  passing locally as root, raising on every runner. Conditional skipping is a
  **tag plus a capability probe**: `test_helper.exs` tries a tmpfs mount once
  and excludes `:requires_mount` when it cannot, which ExUnit then reports as
  "N excluded" rather than hiding it.
- **`mix precommit` passing locally is not CI passing.** The runner is not
  root and cannot mount, and that difference alone broke the suite. Check the
  Tests workflow, not only the Docker one.
- **Every show synced with no path**, so every apply was skipped with
  `:no_plex_path`. A section listing gives a movie its `Media/Part/file` and is
  supposed to give a show a `Location`; the reference server gave neither. The
  fabricated-`provider` lesson again: the parser was written from what the API
  ought to return. Missing paths are now fetched per item
  (`Plex.Client.item_path/3`), falling back to an episode's directory, and only
  for items that have no path from the listing and none stored.
- **`req` was never a declared dependency.** It reached dev and test
  transitively through igniter (`only: [:dev, :test]`), so everything compiled
  and every test passed, and the production release simply did not contain
  it: every Plex call raised `UndefinedFunctionError`. Found by reading a
  `MIX_ENV=prod mix compile --warnings-as-errors` run, not by any test. The
  Dockerfile now compiles strictly before `assets.deploy`, and
  `test/runtime_deps_test.exs` checks that modules used from `lib/` come from
  runtime deps. **A transitive dependency is not a dependency.**
- "Test connection" appeared to reload the page. Two causes with one symptom:
  a URL without a scheme makes Req **raise**, crashing the LiveView (client
  remounts, form clears); and an unreachable host blocks `handle_event` past
  the client's 30s push timeout, and the client rejoins. Long or fallible work
  in a LiveView goes through `start_async`; anything a person types gets
  normalised before it reaches a library that raises on it.
- `ApplyTheme` was unique on `media_item_id` only, so a queued dry run
  silently swallowed the real apply queued after it -- for five minutes, and
  in exactly the order an operator does them. Uniqueness includes the mode.
- `pkill -f "rel/fanfarr/bin"` kills the shell running it, because the pattern
  matches that shell's own command line. Kill by port (`fuser -k 7452/tcp`).
- The generator's `force_ssl` in `config/prod.exs` made the dashboard
  unreachable over LAN, redirecting everything except `localhost` to https.
  The healthcheck kept passing because it requested `localhost` -- the one
  excluded host. **A healthcheck that cannot fail the way users fail is worse
  than none.** Guarded by `test/prod_config_test.exs`.

## AshSqlite limitations found the hard way

The data layer is 0.2.x and genuinely less capable than AshPostgres. Verify
against `deps/ash_sqlite/lib/` rather than assuming parity.

- **No resource-level aggregates at all.** `can?({:aggregate, _})` returns
  false (`data_layer.ex:472`), so a `first`/`count` block in a resource will
  not compile. Only ad-hoc query aggregates work. `ThemeStatus` therefore
  queries the application log itself, batched once per load, rather than
  denormalising the log's state onto the item where it could drift.
- **`ago/2` is not implemented.** AshSqlite ships only `like` and `ilike` as
  custom functions, and an unsupported one fails by *matching nothing* rather
  than raising -- a refresh job would quietly do no work. Compute time cutoffs
  in Elixir and filter on the resulting datetime.
- **`belongs_to` foreign keys are private by default**, so `accept :*` silently
  excludes them and every create fails on a missing relationship. Set
  `attribute_public? true`.

## Versioning

`Fanfarr.Version.display()` -> `"0.1.0 (a1b2c3d)"`, shown bottom-left in the
sidebar and returned by `/health`. The version comes from `mix.exs`; the ref is
the commit, passed as the `BUILD_REF` Docker build arg by the release workflow
and captured **at compile time**, so a running container cannot be made to
misreport itself and the release needs no build env at runtime. A local build
has no ref and says `(dev)` rather than inventing one.

`0.1.0` alone is not enough to identify a build: every `latest` pull between
releases carries it, and self-hosters report bugs by version. Images are already
tagged `latest`, `sha-<sha>` and semver by `docker/metadata-action`; tag a
release `vX.Y.Z` (matching `mix.exs`) to publish a versioned image.

## Applying a theme

`Fanfarr.Workers.ApplyTheme`: intent -> plan -> download -> place -> outcome.

- **Dry run is the default.** `"dry_run" => false` must be passed explicitly.
  A dry run resolves the URL and the destination and checks the directory is
  writable, then stops. That is how a wrong path mapping is found once instead
  of 1,785 times.
- **Local `theme.mp3` only.** Deleting the file undoes it; a Plex API upload
  cannot be undone, and irreversible actions are the project's first rule.
- **Movies are refused** (`:movies_not_supported_yet`). Plex's movie agent
  supplies no themes at all, and whether Plex reads a local theme file for a
  movie is UNVERIFIED. This is the next thing to test on the real server; do
  not implement it from memory.
- Destination resolution order is **map, resolve, then verify**: run the Plex
  path through the mappings, resolve it against the root folders, and check
  existence and writability on the *resolved* directory. Never require the
  reported path to exist locally; on the reference deployment it never does.
- `Fanfarr.Themes.Writer` stages into the destination directory and renames.
  **EXDEV is the expected case on the reference pool**, not an edge case:
  `category.create=mfs` puts a new file on whichever branch has most room, so
  the rename crosses filesystems and falls back to copy-then-unlink. Tested
  against a real second tmpfs mount, because a test that only renames within
  one filesystem proves nothing about this deployment.
- yt-dlp is invoked via `System.cmd/3` with an argument list, never a shell
  string, and URLs are checked against a host allowlist first: the URLs come
  from a third-party database, and yt-dlp accepts local paths and other
  protocols.
- Duration and size ceilings exist because the alternative to rejecting a
  ten-hour video is downloading it onto someone's media drive. yt-dlp exits 0
  when a match-filter rejects a video, so "success with no file" is the normal
  shape of "too long".

## Loudness

Themes arrive from Plex's agent, ThemerrDB and whatever the operator picked,
all mastered differently, so one show blasts and the next is inaudible.
`Fanfarr.Themes.Normalizer` runs EBU R128 `loudnorm` **two-pass** (measure,
then apply exactly that gain) between the download and the write. One pass
adjusts as it goes and pumps on a quiet intro, which is what an opening theme
usually has.

- Target defaults to **-14 LUFS** -- where streaming services sit, so roughly
  where a YouTube-sourced theme is expected to land. It is a setting
  (`theme_loudness_lufs` / `THEME_LOUDNESS_LUFS`) because the right number is
  whatever matches the themes already in the library, and that is measurable
  rather than a matter of opinion: `Normalizer.measure/1` reports any file's
  level without changing it.
- **A normalisation failure is logged and ignored.** An unnormalised theme is
  worse than a normalised one and far better than no theme, so it never turns
  a successful download into a failed apply.
- The recorded `bytes` comes from the file after re-encoding, not before.
- ffmpeg ships in the image; the System page reports it, and tests that need
  it are tagged `:requires_ffmpeg` and excluded where it is missing.

## After the file is written

- **Plex does not notice a new local theme file.** It does not watch the
  filesystem for local assets, so the file sits there until something triggers
  a metadata refresh. The item page has a "Refresh in Plex" button
  (`PUT /library/metadata/<key>/refresh`). Without it the operator sees a
  successful apply and silence in Plex, with nothing saying why.
- For Plex to use the file at all, the library's agent must have **Local Media
  Assets** enabled. That is a Plex library setting, not something Fanfarr can
  set or detect; if a refresh changes nothing, that is the next thing to check.
- **Root folders match by directory name**, so with five drives mounted a show
  called "One Pace" on tv2 and an unrelated folder of the same name on tv4 are
  indistinguishable to the resolver. Writing to the wrong one succeeds and
  reports success, and Plex never plays the theme. The item trace therefore
  compares the resolved directory against a file Plex actually reports for the
  item and says `same folder yes/NO`.
- The written file is playable from the item page (`/library/:id/theme`).
  A download can succeed and still be the wrong audio; a log line saying
  "succeeded" cannot tell anyone that, and listening can.

## Finding a theme: YouTube search

- `Fanfarr.Themes.Downloader.search/2` runs `yt-dlp "ytsearchN:query"
  --dump-json --flat-playlist`. No API key, no quota; one process per search.
- The item page previews with a `youtube-nocookie.com/embed/<id>` iframe. The
  id is validated against `^[A-Za-z0-9_-]{11}$` before it goes near an iframe
  src. Pasted URLs go through the same host allowlist as downloads.
- Picking saves `manual_theme_url` on the item, which outranks ThemerrDB for
  every later apply. Applying does not happen on pick: pick, then Apply.

## Posters

- `/posters/:id` serves from `<config>/cache/posters/`, fetching from Plex on
  a miss via `/photo/:/transcode` (falls back to the raw key). The browser
  never sees a Plex URL or the token. Filenames carry a digest of the thumb
  key, so a new poster is a new file. Failed fetches are not cached.
- Route is session-aware and behind `FanfarrWeb.RequireUserPlug`: posters are
  gated like the pages that show them.

## Health

- `Fanfarr.Health` is plain functions; `Fanfarr.Health.Monitor` runs them every
  10 minutes and on demand and holds the last snapshot. The sidebar dot reads
  the snapshot; nil means no dot. Off in tests (`health_monitor: false`).
- Probes use the same 5-second, no-retry options as the settings test button.

## The System page's log and diagnostics

- `Fanfarr.Log.Buffer` is an Erlang `:logger` handler feeding a bounded, lossy
  ring buffer. It is a debugging aid; the application log in the database is
  the record that must survive.
- **Everything on that page is assumed to become public**, so redaction happens
  at capture, not at render: a secret that never enters the buffer cannot leak
  out of it through a path nobody considered.
- `Fanfarr.Diagnostics.Redactor` **must never touch the database.** Ecto logs
  every query, so a querying redactor would log, which would redact, which
  would query -- one log line spinning forever. Secrets from the database live
  in `:persistent_term`, primed at boot, on save, and on each health tick.
- The theme endpoint serves **range requests**. Without them a media element
  cannot seek within a file it has not finished downloading and cannot read a
  duration without pulling the whole thing -- so a seek bar and a duration
  display are not free, they need the server to support ranges.
- The audio player is drawn from our own tokens rather than `<audio controls>`,
  whose native chrome is a white bar in a dark UI. It is keyed on the theme
  version so a newly written file replaces the node; the hook pauses and
  clears the source in `destroyed()`, or the old theme keeps playing over it.
- `record_local_theme!` must run **before** `record_outcome`, because the
  latter broadcasts. The other order meant a subscriber reloaded with the
  previous file's timestamp and the player kept the old audio until the page
  was refreshed by hand.
- Long paths must not widen the page: the destination path in the history
  table and the written-file path both `break-all`, and the table scrolls
  inside its own container. A `truncate` inside a table cell does nothing --
  the table just grows and takes the page with it.
- Diagnostics tools run under `start_async`: they shell out to yt-dlp, call
  Plex and touch the filesystem, none of which may hold the page or crash it.
- `plex_probe/1` only accepts server-relative paths, so it can reach the
  operator's own Plex and nothing else.

## Versioning

Patch versions bump **automatically** on every push to main, in the `version`
job of `docker.yml`. A semver is what a person can actually hold in their head
and quote back ("I'm on 0.1.7"), which a sha is not, and automating it means it
cannot be forgotten.

The bump runs **before** the build, in the same workflow, and the build checks
out the commit it produced -- otherwise the image would be tagged with a
version it does not report. Images get `latest`, `sha-<sha>` and `X.Y.Z`.

There is no loop, because a push made with `GITHUB_TOKEN` does not trigger
workflows. That is also why the bump cannot live in its own workflow reacting
to the commit: nothing would react to it.

`version.yml` remains for the bumps that are a judgement -- a minor or major,
plus the git tag and GitHub release that go with a deliberate version.
`test/runtime_deps_test.exs` guards that both paths rewrite `mix.exs` and that
the build depends on the bump.

## Conventions

- Run `mix precommit` before finishing (compile --warnings-as-errors, unused
  deps, format, test).
- Commit messages: what changed and *why it matters*, in prose. No model names,
  no emoji.
- Verify claims about libraries against source in `deps/` rather than memory.
- CI publishes `ghcr.io/dyonng/fanfarr:latest` on push to `main`. The package
  is public.

## State

Done: scaffold, SQLite tuning, containerisation + GHCR, path mapping, root
folder resolution, vendored UI, deployment docs, resource model, auth
(single-user, password only, no mailer), Plex client behaviour + HTTP impl
(**read paths verified** against PMS 1.43.4 and pinned as captured-response
tests; **write paths -- upload_theme, lock_theme -- still UNVERIFIED**), sync/ThemerrDB Oban workers,
dashboard (Library, Item, Activity, Settings), theme origin detection.
CLAUDE.md carries operational notes.

Next: the yt-dlp resolver and theme writer (EXDEV fallback required), then the
ApplyTheme worker with dry-run defaulting on. The first real upload also
settles the `upload://` ratingKey shape above.

---

This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->


<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")
