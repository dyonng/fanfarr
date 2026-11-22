# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Single operator (the self-hoster) on their own LAN, triaging theme music for
a Plex library of thousands of titles. No household audience, no onboarding
funnel: every second spent explaining is a second stolen from the task.

## Product Purpose

Keep every title's theme music present and correct with minimum operator
attention: find what's missing or failed, judge the candidate, apply it, and
move on. Success is a short Needs-attention list and applies the operator
trusts without re-listening.

## Positioning

The theme pipeline owns the whole loop -- discovery (ThemerrDB + YouTube
search), audition (trim editor, previews), application (writes + hands to
Plex), and proof (history log) -- where neighboring tools do one step. No
other Plex companion does find-listen-trim-apply in one place.

## Operating Context

Self-hosted Docker on a media server, same LAN as Plex. Operator works in
short sessions, usually on desktop, clearing the failed/missing queue. Phone
use is checking, not doing. YouTube breaks often; Plex re-scans on its own
schedule.

## Capabilities and Constraints

Finds themes via ThemerrDB and YouTube search; trims with loudness-matched
fades; writes local theme.mp3 and promotes it in Plex; keeps a permanent
application history. Plex uploads are irreversible -- the app never uploads
except the deliberate per-item diagnostic. No automatic uploads, ever. Single
SQLite file, Oban inside it. YouTube is the flaky dependency; every fetch
assumes it can fail.

## Brand Commitments

Dark *arr-suite chrome (Sonarr/Radarr lineage): dense data tables, muted
surfaces, one accent. Keep the vibe; execute it far better. Lucide icons,
shadcn-derived components, tabular numerals. No light mode.

## Evidence on Hand

The running app itself with a real ~2.7k-title library; screenshots not yet
captured this session. Item/library/overview/settings pages in
lib/fanfarr_web/live/.

## Product Principles

1. The queue is the product: missing and failed titles surface themselves;
   everything else stays out of the way.
2. Every apply is previewable and every write is explainable -- the log is
   the receipt.
3. One operator, zero ceremony: no confirmations that don't prevent
   irreversible harm, no onboarding, no empty states that lecture.
4. Automation earns trust by showing its work, not by asking permission.

## Accessibility & Inclusion

Single known user, no mandated standard. Keyboard-first operation is a
want, not a requirement; touch targets already meet mobile sizes.
