# ThemerrDB — endpoint shape, schema, and access notes

Status: **verified against live responses** (2026-08-31), except where marked.

## Endpoint

```
https://app.lizardbyte.dev/ThemerrDB/{item_type}/{database}/{external_id}.json
```

| Segment       | Values                                                             |
|---------------|--------------------------------------------------------------------|
| `item_type`   | `movies`, `tv_shows`                                               |
| `database`    | `imdb`, `themoviedb` — `thetvdb` unverified, see below             |
| `external_id` | The provider's own ID (e.g. `tt0137523`, `550`)                    |

`200` with a JSON object, or `404` when the title is absent.

The project brief inferred this shape from Themerr-plex plugin source and listed
`thetvdb` as a valid `database`. The reference implementation we read
(`TimoVerbrugghe/Themarr`) only ever queries `imdb` and `themoviedb`. We have not
confirmed whether `thetvdb` works — treat it as unverified.

## Response schema

**The response is a full TMDB metadata object with five theme fields grafted on.**
It is not a slim theme record. A movie carries ~32 top-level keys, a TV show ~38 —
`genres`, `overview`, `production_companies`, `seasons`, `poster_path`, and so on,
straight from TMDB.

The fields that are ours:

| Field                     | Type          | Meaning                              |
|---------------------------|---------------|--------------------------------------|
| `youtube_theme_url`       | string        | The theme. Resolve with `yt-dlp`.    |
| `youtube_theme_added`     | int (unix ts) | When the theme was first contributed |
| `youtube_theme_added_by`  | string        | Contributor user ID                  |
| `youtube_theme_edited`    | int (unix ts) | When it was last changed             |
| `youtube_theme_edited_by` | string        | Last editor's user ID                |

The reference implementation reads only `youtube_theme_url` and ignores the rest.
That is a missed opportunity — see "Change detection" below.

### Observed payload sizes

| Title                     | Type  | Bytes  |
|---------------------------|-------|--------|
| Fight Club (tmdb 550)     | movie | 2,750  |
| Breaking Bad (tmdb 1396)  | show  | 7,207  |
| One Piece (tmdb 37854)    | show  | 22,696 |

Roughly 3–23 KB, skewing larger for long-running shows with many seasons. At ~5 KB
average, a cold sync of a 2,550-item library moves on the order of **12 MB across
2,550 requests**. Tolerable, but not something to repeat casually.

## Change detection — use `youtube_theme_edited`

This is the most useful thing in the payload beyond the URL itself. Persist it
alongside each cached entry and compare on re-sync: if it has not moved, the theme
has not changed and there is nothing to re-resolve, regardless of cache TTL. If it
has moved, the community has corrected or replaced the theme and we should re-resolve
and offer the update.

This gives the health/drift feature a real signal instead of a heuristic, and it lets
routine re-syncs skip almost all work.

## Lookup strategy (as implemented upstream)

1. Try `imdb` with the item's IMDB ID.
2. Fall back to `themoviedb` with the TMDB ID.
3. First hit wins; nothing if neither resolves.

The result is cached under **every** known external ID for the item (IMDB, TMDB,
TVDB), so a later lookup keyed by any one of them hits.

## Access characteristics

- **No bulk or index endpoint is known.** Access is one HTTP request per title.
  Whether a bulk export exists is still an open question for LizardByte, and it is
  the highest-value one — it is the difference between 1 request and 2,550.
- Upstream caches 24 hours, in memory, behind a lock, and **caches 404s too** —
  important, since misses are common and would otherwise re-request every cycle.
- That cache is process-local and dies on restart. Ours persists in SQLite, with the
  TTL and `youtube_theme_edited` as columns rather than a process lifetime.

## Security note worth copying

Upstream validates external IDs against `^[A-Za-z0-9_\-]{1,64}$` before interpolating
them into the URL, guarding against path traversal or header injection from a
malformed upstream metadata value. Do the same — these IDs come from Plex, which we
do not control.

## Still open

1. Whether a bulk export or index file exists. **Highest value.**
2. Whether `thetvdb` is a valid `database` value.
3. Rate limits, and whether third-party programmatic access is welcome.
4. How to contribute new themes back.

These are the substance of the issue to open against `LizardByte/Themerr-plex`.
