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

rule "Server"
q "/" | grep -oE 'friendlyName="[^"]*"|version="[^"]*"|platform="[^"]*"' | head -3

rule "Libraries"
q "/library/sections" \
  | grep -oE '<Directory[^>]*>' \
  | grep -oE 'key="[0-9]+"|type="[a-z]+"|title="[^"]*"' \
  | paste - - - 2>/dev/null

# --- coverage per library ---------------------------------------------------
for KEY in $(q "/library/sections" | grep -oE '<Directory[^>]*type="(show|movie)"[^>]*>' | grep -oE 'key="[0-9]+"' | cut -d'"' -f2); do
  TITLE="$(q "/library/sections/$KEY" | grep -oE 'librarySectionTitle="[^"]*"' | head -1 | cut -d'"' -f2)"
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
  NAME="$(q "/library/metadata/$SAMPLE" | grep -oE 'title="[^"]*"' | head -1 | cut -d'"' -f2)"
  echo "Sampling: $NAME (ratingKey $SAMPLE)"
  echo
  q "/library/metadata/$SAMPLE/themes"
  echo
  echo "-- provider values seen across this sample:"
  q "/library/metadata/$SAMPLE/themes" | grep -oE 'provider="[^"]*"' | sort -u | sed 's/^/     /'
  echo "   (no output above means Plex reports no provider -- we then cannot"
  echo "    distinguish its own themes from uploads, and must rely on our log)"
else
  echo "No item with a theme found, so there is nothing to sample."
fi

rule "Done"
echo "Nothing above contains your token."
