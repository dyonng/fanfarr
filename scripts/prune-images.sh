#!/usr/bin/env bash
#
# Reclaim the space a stack of pulled images accumulates.
#
# Every rebuild pulls a new image and leaves the previous one behind as an
# untagged layer set. Measured on this host: four dangling images at 420 MB,
# 655 MB, 655 MB and 863 MB, and `docker system df` reporting 14 GB
# reclaimable in total.
#
#   scripts/prune-images.sh             dangling images + build cache
#   scripts/prune-images.sh --all       also unused *tagged* images
#   scripts/prune-images.sh --dry-run   say what would go, remove nothing
#
# KEEP_HOURS=72 scripts/prune-images.sh --all    change the grace period
#
# It deliberately does not prune containers. A compose stack with a one-shot
# service -- an init container that chowns a volume and exits, like chown-fix
# in the media-stack -- has a stopped container that is still part of the
# stack, and `docker container prune` deletes exactly that.
#
# Fanfarr itself has no access to this: the app runs without the Docker
# socket, so nothing that reaches the dashboard can reconsider your images.
#
# To run it nightly, install a timer. That needs root, which is why it is not
# installed here:
#
#   /etc/systemd/system/fanfarr-prune.service
#     [Unit]
#     Description=Prune dangling Docker images
#     [Service]
#     Type=oneshot
#     User=dyonng
#     ExecStart=%h/agent-canvas-workspace/fanfarr/scripts/prune-images.sh
#
#   /etc/systemd/system/fanfarr-prune.timer
#     [Unit]
#     Description=Nightly Docker prune
#     [Timer]
#     OnCalendar=daily
#     Persistent=true
#     [Install]
#     WantedBy=timers.target
#
#   sudo systemctl enable --now fanfarr-prune.timer

set -euo pipefail

DRY_RUN=0
ALL=0

# A week by default: an image pulled in the last few days may be the one a
# rollback needs, and reclaiming it costs a re-pull of something still in use
# by a stopped stack.
KEEP_HOURS="${KEEP_HOURS:-168}"

usage() {
  cat <<'USAGE'
usage: prune-images.sh [--all] [--dry-run]

  (no options)  remove dangling (untagged) images and the build cache
  --all         also remove unused tagged images older than KEEP_HOURS
  --dry-run     list what would go and remove nothing

environment:
  KEEP_HOURS    grace period for --all, in hours (default 168)
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || {
  echo "docker is not on PATH" >&2
  exit 1
}

echo "before:"
docker system df

echo
if [ "$ALL" = "1" ]; then
  echo "unused tagged images older than ${KEEP_HOURS}h, and dangling ones"
  if [ "$DRY_RUN" = "1" ]; then
    docker images --format '  {{.Repository}}:{{.Tag}}  {{.CreatedSince}}  {{.Size}}'
  else
    docker image prune --all --force --filter "until=${KEEP_HOURS}h"
  fi
else
  echo "dangling images"
  if [ "$DRY_RUN" = "1" ]; then
    docker images --filter dangling=true --format '  {{.ID}}  {{.CreatedSince}}  {{.Size}}'
  else
    docker image prune --force
  fi
fi

echo
echo "build cache"
if [ "$DRY_RUN" = "1" ]; then
  docker builder du 2>/dev/null | tail -3 || echo "  (buildx has no size to report)"
else
  docker builder prune --force
fi

if [ "$DRY_RUN" = "0" ]; then
  echo
  echo "after:"
  docker system df
fi
