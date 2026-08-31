#!/bin/bash
# Entrypoint for the Fanfarr container.
#
# Matches the *arr convention: the container starts as root, adjusts the
# service account to the PUID/PGID the operator asked for, fixes ownership of
# the paths it owns, then drops privileges. This matters more here than for
# most services -- Fanfarr's local-theme output mode writes theme.mp3 files
# into the media library, and files owned by the wrong user are a real problem
# for everything else in the stack.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CONFIG_DIR="${FANFARR_CONFIG_DIR:-/config}"

if [ "$(id -u)" = "0" ]; then
  # Re-point the service account at the requested ids. groupmod/usermod are
  # no-ops when the ids already match, so a restart costs nothing.
  if [ "$(id -g fanfarr)" != "$PGID" ]; then
    groupmod -o -g "$PGID" fanfarr
  fi
  if [ "$(id -u fanfarr)" != "$PUID" ]; then
    usermod -o -u "$PUID" fanfarr
  fi

  mkdir -p "$CONFIG_DIR"

  # Only chown when it is actually wrong. On a config volume with many cached
  # posters an unconditional recursive chown adds seconds to every start.
  if [ "$(stat -c %u "$CONFIG_DIR")" != "$PUID" ] || [ "$(stat -c %g "$CONFIG_DIR")" != "$PGID" ]; then
    echo "[fanfarr] adjusting ownership of $CONFIG_DIR to ${PUID}:${PGID}"
    chown -R "$PUID:$PGID" "$CONFIG_DIR"
  fi

  # The release directory is chowned at build time; this catches the case where
  # PUID/PGID differ from the build-time defaults.
  if [ "$(stat -c %u /app)" != "$PUID" ]; then
    chown -R "$PUID:$PGID" /app
  fi

  echo "[fanfarr] starting as ${PUID}:${PGID}"
  exec gosu "$PUID:$PGID" "$@"
fi

# Already unprivileged -- the operator set `user:` in compose, so PUID/PGID are
# not ours to apply. Run as whoever we are.
echo "[fanfarr] running as $(id -u):$(id -g) (not root; PUID/PGID ignored)"
exec "$@"
