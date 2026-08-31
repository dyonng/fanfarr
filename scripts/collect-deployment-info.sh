#!/usr/bin/env bash
# Collects the details needed to configure Fanfarr's media volumes correctly.
#
# Read-only: inspects Docker, systemd and the filesystem, changes nothing.
# Container environments are skipped so tokens never reach the output. The one
# exception is the optional Plex API section, which needs a token you pass in
# explicitly and which prints only library paths, never the token itself.
#
#   bash scripts/collect-deployment-info.sh
#   PLEX_TOKEN=xxx bash scripts/collect-deployment-info.sh    # adds section 8
set -uo pipefail

PLEX_CONTAINER="${PLEX_CONTAINER:-plex}"
PLEX_URL="${PLEX_URL:-http://localhost:32400}"

rule() { printf '\n=== %s ===\n' "$1"; }

rule "1. Where does Plex run?"
echo "Fanfarr resolves a show's folder from the path Plex reports, so this"
echo "determines whether those are container paths or host paths."
if docker inspect "$PLEX_CONTAINER" >/dev/null 2>&1; then
  echo "Plex runs in a container. Its mounts (these are the paths that matter):"
  docker inspect "$PLEX_CONTAINER" \
    --format '{{range .Mounts}}  {{.Source}}  ->  {{.Destination}}  ({{.Mode}}{{if .Propagation}},{{.Propagation}}{{end}}){{"\n"}}{{end}}'
else
  echo "No container named '$PLEX_CONTAINER'. Checking for a host install:"
  if systemctl status plexmediaserver >/dev/null 2>&1; then
    echo "  Plex runs on the HOST via systemd (plexmediaserver)."
    echo "  It therefore reports HOST paths, and Fanfarr should mount those"
    echo "  paths at the identical container path so no translation is needed."
    systemctl show plexmediaserver -p MainPID -p ActiveState 2>/dev/null | sed 's/^/    /'
  elif pgrep -af '[P]lex Media Server' >/dev/null 2>&1; then
    echo "  Plex is running on the HOST (found the process, not managed by systemd):"
    pgrep -af '[P]lex Media Server' | head -2 | cut -c1-120 | sed 's/^/    /'
  else
    echo "  Plex not found locally -- it may be on another machine."
    echo "  If so, set PLEX_URL and note that its paths are that machine's."
  fi
fi

rule "2. Plex data directory"
echo "Uploaded themes land here. Tells us whether the 'themes cannot be deleted"
echo "via the API' constraint is recoverable by hand."
for p in \
  "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server" \
  "$HOME/Library/Application Support/Plex Media Server"; do
  [ -d "$p" ] && echo "  FOUND: $p" && du -sh "$p" 2>/dev/null | sed 's/^/    /'
done
docker inspect "$PLEX_CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/config"}}  container /config -> {{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null

rule "3. Filesystems and free space"
df -hT /media/* 2>/dev/null | grep -v tmpfs || df -hT 2>/dev/null | head -20

rule "4. mergerfs pools"
if command -v mergerfs >/dev/null 2>&1; then
  echo "Installed: $(mergerfs --version 2>&1 | head -1)"
else
  echo "mergerfs is NOT installed."
fi
echo "-- active pools:"
mount | grep -Ei 'mergerfs|fuse\.' | sed 's/^/  /' || echo "  (none)"

rule "5. mergerfs create policy  << THE IMPORTANT ONE >>"
echo "Decides which drive a NEW file lands on. A path-preserving policy (epmfs,"
echo "eplfs, epff, msplfs) keeps a theme.mp3 on the same drive as its show and"
echo "makes the rename atomic. A non-preserving one (mfs, lfs, rand) can put it"
echo "on a different drive, which fragments the show and makes rename fail with"
echo "EXDEV. mergerfs does not report this in /proc/mounts, so we read how the"
echo "pool was mounted."
echo "-- /etc/fstab:"
grep -i 'mergerfs\|merged-storage' /etc/fstab 2>/dev/null | sed 's/^/  /' || echo "  (no matching fstab entries)"
echo "-- systemd mount units:"
systemctl list-units --type=mount --all --no-legend 2>/dev/null | grep -i 'merged\|storage' | sed 's/^/  /' || echo "  (none)"
for u in $(systemctl list-unit-files --type=mount --no-legend 2>/dev/null | awk '{print $1}' | grep -i 'merged\|storage'); do
  echo "  -- $u:"
  systemctl cat "$u" 2>/dev/null | grep -iE 'what=|where=|options=' | sed 's/^/    /'
done
echo "-- any mergerfs process (its full argv shows the options in use):"
pgrep -af mergerfs 2>/dev/null | head -5 | sed 's/^/  /' || echo "  (pool mounted but no live process found)"

rule "6. Mount propagation"
echo "'shared' or 'slave' means a container is told when host mounts change."
echo "'private' means it is not -- so if a pool remounts, the container keeps"
echo "looking at the empty directory underneath and the library appears empty."
if command -v findmnt >/dev/null 2>&1; then
  findmnt -no TARGET,PROPAGATION,FSTYPE /media/* 2>/dev/null | sed 's/^/  /'
else
  echo "  (findmnt unavailable -- reading /proc/self/mountinfo directly)"
  awk '$5 ~ /^\/media/ {
    prop = "private"
    for (i = 7; i <= NF; i++) {
      if ($i == "-") break
      if ($i ~ /^shared:/) prop = "shared"
      else if ($i ~ /^master:/) prop = "slave"
    }
    print "  " $5 "  " prop
  }' /proc/self/mountinfo 2>/dev/null
fi

rule "7. Ownership of the media roots"
for d in /media/*/; do
  [ -d "$d" ] && stat -c '  %U:%G (%u:%g)  %n' "$d" 2>/dev/null
done

rule "8. Plex library paths (needs PLEX_TOKEN)"
if [ -n "${PLEX_TOKEN:-}" ]; then
  echo "The definitive answer: the exact paths Plex will report to Fanfarr."
  curl -sS --max-time 15 "${PLEX_URL}/library/sections?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null \
    | grep -oE '(title|path)="[^"]*"' | sed 's/^/  /' \
    || echo "  (request failed -- check PLEX_URL and that Plex is reachable)"
else
  echo "Skipped. To include it:"
  echo "  PLEX_TOKEN=<your-token> bash scripts/collect-deployment-info.sh"
  echo "Only library titles and paths are printed; the token is never echoed."
fi

rule "Done"
echo "Paste this output back. Nothing here contains a token or password."
