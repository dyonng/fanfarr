#!/usr/bin/env bash
# Collects the details needed to configure Fanfarr's media volumes correctly.
#
# Read-only: inspects Docker and the filesystem, changes nothing. Secrets are
# not printed -- container environments are skipped entirely, so tokens in
# PLEX_TOKEN and friends never reach the output. Read it before running it.
#
#   bash scripts/collect-deployment-info.sh          # print to screen
#   bash scripts/collect-deployment-info.sh > out.txt
set -uo pipefail

PLEX_CONTAINER="${PLEX_CONTAINER:-plex}"

rule() { printf '\n=== %s ===\n' "$1"; }

rule "1. Plex container volume mounts"
echo "These are the paths that matter: Fanfarr must see the library at the same"
echo "container path Plex does, or be told how to translate."
if docker inspect "$PLEX_CONTAINER" >/dev/null 2>&1; then
  docker inspect "$PLEX_CONTAINER" \
    --format '{{range .Mounts}}{{.Source}}  ->  {{.Destination}}  ({{.Mode}}{{if .Propagation}},{{.Propagation}}{{end}}){{"\n"}}{{end}}'
else
  echo "No container named '$PLEX_CONTAINER'."
  echo "Re-run as: PLEX_CONTAINER=<name> bash scripts/collect-deployment-info.sh"
  echo "Containers currently running:"
  docker ps --format '  {{.Names}}  ({{.Image}})' 2>/dev/null || echo "  (docker unavailable)"
fi

rule "2. Where Plex stores its own data"
echo "Uploaded themes land in Plex's data directory. Knowing where it is tells"
echo "us whether the 'themes cannot be deleted via the API' problem is"
echo "recoverable by hand."
docker inspect "$PLEX_CONTAINER" \
  --format '{{range .Mounts}}{{if or (eq .Destination "/config") (eq .Destination "/data")}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
  || echo "  (unavailable)"

rule "3. Filesystems and free space"
echo "One line per drive. Shows whether these are separate filesystems and how"
echo "much room each has."
df -hT /media/* 2>/dev/null | grep -v tmpfs || df -hT 2>/dev/null | head -20

rule "4. Is anything already pooled?"
if command -v mergerfs >/dev/null 2>&1; then
  echo "mergerfs is installed: $(mergerfs --version 2>&1 | head -1)"
else
  echo "mergerfs is NOT installed."
fi
echo "-- fuse/mergerfs mounts currently active:"
mount | grep -Ei 'mergerfs|fuse\.' || echo "  (none)"

rule "5. Mount propagation on the media paths"
echo "'shared' or 'slave' means a container is told when the host's mounts"
echo "change. 'private' means it is not -- which matters only if you later pool"
echo "these drives."
findmnt -no TARGET,PROPAGATION,FSTYPE,SOURCE /media/* 2>/dev/null || echo "  (findmnt unavailable)"

rule "6. Ownership of the media roots"
echo "Fanfarr's PUID/PGID must match these, or Plex will not be able to read"
echo "the theme files it writes."
for d in /media/*/; do
  [ -d "$d" ] && stat -c '  %U:%G (%u:%g)  %n' "$d" 2>/dev/null
done

rule "7. A real library folder"
echo "Confirms the on-disk layout Fanfarr will write theme.mp3 into, and"
echo "whether any themes already exist."
for d in /media/*/; do
  for sub in TV MorePlex/TV Plexifer/TV; do
    if [ -d "${d}${sub}" ]; then
      echo "  ${d}${sub}"
      find "${d}${sub}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -3 | sed 's/^/      /'
      break
    fi
  done
done
echo "-- theme.mp3 files already present (first 5):"
find /media -maxdepth 5 -name 'theme.mp3' 2>/dev/null | head -5 || true
echo "-- total theme.mp3 count:"
find /media -maxdepth 5 -name 'theme.mp3' 2>/dev/null | wc -l

rule "Done"
echo "Paste this output back. Nothing here contains a token or password."
