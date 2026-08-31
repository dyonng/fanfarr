# ThemerrDB — endpoint shape and access notes

Status: **partially verified.** The URL shape below is confirmed by a working
third-party implementation (`TimoVerbrugghe/Themarr`, `app/themerrdb_service.py`),
not by published API docs. The response schema is only partially known — see
"Still unknown" below. Verify against live responses before relying on details.

## Endpoint

```
https://app.lizardbyte.dev/ThemerrDB/{item_type}/{database}/{external_id}.json
```

| Segment       | Values                                                        |
|---------------|---------------------------------------------------------------|
| `item_type`   | `movies`, `tv_shows`                                          |
| `database`    | `imdb`, `themoviedb` — `thetvdb` is *not* used by the impl we read |
| `external_id` | The provider's own ID (e.g. `tt0388629`, `37854`)             |

Responses: `200` with a JSON object, or `404` when the title is not in the database.

The original project brief inferred this shape from Themerr-plex plugin source and
listed `thetvdb` as a valid `database`. The implementation we read only ever queries
`imdb` and `themoviedb`. That does not prove `thetvdb` is unsupported — it was simply
never used. Treat it as unverified.

## Known response fields

- `youtube_theme_url` — a YouTube URL that must be resolved to audio with `yt-dlp`.

That is the only field the reference implementation reads. The payload is passed
around as an opaque dict elsewhere, so other fields likely exist but are unused.

## Lookup strategy (as implemented upstream)

1. Try `imdb` with the item's IMDB ID.
2. Fall back to `themoviedb` with the TMDB ID.
3. First hit wins; `None` if neither resolves.

The result is then cached under **every** known external ID for that item
(IMDB, TMDB, and TVDB), so a later lookup keyed by any one of them hits the cache.

## Access characteristics

- **No bulk or index endpoint is used.** Access is strictly one HTTP request per
  title. For a library of ~2,550 items, a cold sync is ~2,550 requests. Whether a
  bulk export exists is an open question for LizardByte.
- Upstream caches for **24 hours**, in memory, behind a lock. Negative results
  (404s) are cached too — important, since misses are common and would otherwise
  re-request every cycle.
- That cache is process-local and lost on restart. Our SQLite mirror should persist
  it instead, with the TTL as a column rather than a process lifetime.

## Security note worth copying

Upstream validates the external ID against `^[A-Za-z0-9_\-]{1,64}$` before
interpolating it into the URL, to stop a compromised or malformed upstream metadata
value from causing path traversal or header injection. Do the same — the IDs
originate from Plex, which we do not fully control.

## Still unknown

1. Full response schema beyond `youtube_theme_url`.
2. Whether a bulk export or index file exists. **This is the single biggest open
   question** — it determines whether first sync is 1 request or 2,550.
3. Whether `thetvdb` is a valid `database` value.
4. Rate limits, and whether third-party programmatic access is welcome.
5. How to contribute new themes back to the database.

Items 2–5 are the substance of the issue to open against `LizardByte/Themerr-plex`.
Item 1 can be settled by fetching a handful of live entries once network egress to
`app.lizardbyte.dev` is available.
