#!/bin/sh
# Run the test suite in several operating-system processes, each with its own
# SQLite database.
#
# The database-backed tests cannot share one file. SQLite has a single writer and
# Ecto's sandbox holds a transaction open per test, so concurrent tests collide
# rather than queue: flipping 32 files to `async: true` against a shared file
# produced 483 to 625 failures out of 846.
#
# `mix test --partitions N` splits the suite across partitions; it does not start
# the processes itself, and it requires MIX_TEST_PARTITION to say which one this
# process is. This script is the other half: migrate one database, give each
# partition a copy of it, run the partitions concurrently, and fail if any of
# them failed.
#
#   scripts/test-parallel.sh              # 4 partitions
#   TEST_PARTITIONS=8 scripts/test-parallel.sh
#   scripts/test-parallel.sh test/fanfarr/workers/trim_theme_test.exs
set -eu

partitions="${TEST_PARTITIONS:-4}"
base="fanfarr_test.db"

echo "test-parallel: preparing $partitions databases"
mix ash.setup --quiet

# Compile once, before fanning out. Four partitions starting cold would each
# compile the same _build directory at the same time, and those early runs are
# where the intermittent failures came from.
mix compile --warnings-as-errors >/dev/null

for i in $(seq 1 "$partitions"); do
  # A write-ahead log beside a database is part of that database: copying only
  # the .db file would drop whatever is still in the log.
  for suffix in "" "-wal" "-shm"; do
    if [ -f "$base$suffix" ]; then
      cp -f "$base$suffix" "fanfarr_test_$i.db$suffix"
    else
      rm -f "fanfarr_test_$i.db$suffix"
    fi
  done
done

pids=""
for i in $(seq 1 "$partitions"); do
  MIX_TEST_PARTITION="$i" mix test --partitions "$partitions" "$@" &
  pids="$pids $!"
done

status=0
for pid in $pids; do
  wait "$pid" || status=1
done

exit "$status"
