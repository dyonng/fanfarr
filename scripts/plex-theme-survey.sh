#!/usr/bin/env bash
#
# Surveys theme coverage in a Plex library, and shows what Plex actually
# reports about a theme's origin.
#
# Answers two questions:
#   1. How many titles already have a theme, and how many do not -- the real
#      size of the job Fanfarr exists to do.
#   2. What /library/metadata/<id>/themes returns, in particular whether Plex
#      names a `provider`. If it does, we can tell a Plex-supplied theme from
#      an uploaded one directly instead of inferring it.
#
# Read-only. The token is read from Plex's own config and never printed.
#
#   bash scripts/plex-theme-survey.sh
#   PLEX_URL=http://192.168.1.121:32400 bash scripts/plex-theme-survey.sh
set -uo pipefail

PLEX_URL="${PLEX_URL:-http://localhost:32400}"
PREFS="${PLEX_PREFS:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml}"

rule() { printf '\n=== %s ===\n' "$*"; }

# --- token ------------------------------------------------------------------
TOKEN="${PLEX_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  if sudo test -r "$PREFS" 2>/dev/null; then
    TOKEN="$(sudo grep -o 'PlexOnlineToken="[^"]*"' "$PREFS" | cut -d'"' -f2)"
  fi
fi

if [ -z "$TOKEN" ]; then
  echo "Could not read a Plex token."
  echo "Either pass one:      PLEX_TOKEN=xxx bash $0"
  echo "or point at prefs:    PLEX_PREFS=/path/to/Preferences.xml bash $0"
  echo
  echo "To find a token by hand: open any item in Plex web, click ... -> Get Info"
  echo "-> View XML, and copy X-Plex-Token from the URL."
  exit 1
fi
echo "Token loaded (${#TOKEN} chars, not printed)."

q() { curl -sS --max-time 30 -H "X-Plex-Token: $TOKEN" "$PLEX_URL$1"; }
# Same request the app makes: Plex answers in JSON when asked to. Everything in
# Fanfarr.Plex.HTTPClient parses JSON, so this is the shape that actually matters.
qj() { curl -sS --max-time 30 -H "X-Plex-Token: $TOKEN" -H "Accept: application/json" "$PLEX_URL$1"; }

# The XML declaration is itself `<?xml version="1.0"?>`, so a naive grep for
# version= finds that instead of the server's. Drop it before matching.
nodecl() { sed 's/<?xml[^>]*?>//'; }

attr() { grep -oE "$1=\"[^\"]*\"" | head -1 | cut -d'"' -f2; }

rule "Server"
SERVER="$(q "/" | nodecl)"
printf '  name:     %s\n' "$(printf '%s' "$SERVER" | attr friendlyName)"
printf '  version:  %s\n' "$(printf '%s' "$SERVER" | attr version)"
printf '  platform: %s\n' "$(printf '%s' "$SERVER" | attr platform)"

rule "Does Plex answer in JSON?"
# Unverified until now, and load-bearing: if this is not JSON, every parse in
# the app silently returns empty rather than failing loudly.
JSON="$(qj "/library/sections")"
case "$JSON" in
  \{*) echo "  YES -- responses start with '{'. The app's JSON parsing is correct." ;;
  "<"*) echo "  NO  -- Plex returned XML despite Accept: application/json." ;;
  *)    echo "  UNCLEAR -- response starts: $(printf '%s' "$JSON" | cut -c1-40)" ;;
esac

rule "Libraries"
SECTIONS="$(q "/library/sections")"
printf '%s' "$SECTIONS" | grep -oE '<Directory[^>]*>' | while read -r DIR; do
  printf '  key=%-3s type=%-8s title=%s\n' \
    "$(printf '%s' "$DIR" | attr key)" \
    "$(printf '%s' "$DIR" | attr type)" \
    "$(printf '%s' "$DIR" | attr title)"
done

# --- coverage per library ---------------------------------------------------
for KEY in $(printf '%s' "$SECTIONS" | grep -oE '<Directory[^>]*type="(show|movie)"[^>]*>' | grep -oE 'key="[0-9]+"' | cut -d'"' -f2); do
  # Take the title from the section list we already have, rather than a second
  # request for librarySectionTitle that came back empty.
  TITLE="$(printf '%s' "$SECTIONS" | grep -oE "<Directory[^>]*key=\"$KEY\"[^>]*>" | attr title)"
  [ -z "$TITLE" ] && TITLE="section $KEY"

  ALL="/tmp/plex-section-$KEY.xml"
  q "/library/sections/$KEY/all" > "$ALL"

  TOTAL=$(grep -cE '<(Directory|Video) ' "$ALL")
  WITH=$(grep -cE '<(Directory|Video)[^>]* theme="' "$ALL")
  WITHOUT=$(( TOTAL - WITH ))

  rule "Coverage: $TITLE (section $KEY)"
  printf '  total:        %s\n  with theme:   %s\n  WITHOUT:      %s\n' "$TOTAL" "$WITH" "$WITHOUT"
  if [ "$TOTAL" -gt 0 ]; then
    printf '  coverage:     %s%%\n' "$(( WITH * 100 / TOTAL ))"
  fi

  echo "  -- examples WITHOUT a theme:"
  grep -oE '<(Directory|Video)[^>]*>' "$ALL" | grep -v ' theme="' \
    | grep -oE 'title="[^"]*"' | cut -d'"' -f2 | head -5 | sed 's/^/       /'
done

# --- what Plex says about a theme's origin ----------------------------------
rule "What /themes returns  << the interesting part >>"
SAMPLE=""
for f in /tmp/plex-section-*.xml; do
  [ -f "$f" ] || continue
  SAMPLE="$(grep -oE '<(Directory|Video)[^>]* theme="[^>]*>' "$f" \
    | grep -oE 'ratingKey="[0-9]+"' | head -1 | cut -d'"' -f2)"
  [ -n "$SAMPLE" ] && break
done

if [ -n "$SAMPLE" ]; then
  NAME="$(q "/library/metadata/$SAMPLE" | nodecl | attr title)"
  echo "Sampling: $NAME (ratingKey $SAMPLE)"

  echo
  echo "-- the listing's own theme attribute (does it encode origin?):"
  grep -oE "<(Directory|Video)[^>]* ratingKey=\"$SAMPLE\"[^>]*>" /tmp/plex-section-*.xml \
    | grep -oE 'theme="[^"]*"' | head -1 | sed 's/^/     /'

  echo
  echo "-- /themes as XML:"
  q "/library/metadata/$SAMPLE/themes"

  echo
  echo "-- /themes as JSON (what the app actually parses):"
  qj "/library/metadata/$SAMPLE/themes"

  echo
  echo "-- ratingKey schemes seen (this is where origin lives):"
  q "/library/metadata/$SAMPLE/themes" | grep -oE 'ratingKey="[^"]*"' | cut -d'"' -f2 \
    | sed 's/^/     /'
else
  echo "No item with a theme found, so there is nothing to sample."
fi

rule "Done"
echo "Nothing above contains your token."
