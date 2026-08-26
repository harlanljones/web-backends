#!/usr/bin/env bash
# Wait for /seed/*.csv before the standard postgres entrypoint runs.
#
# The seeder service writes the CSVs to the seed-out volume. The official
# postgres entrypoint does not know about the seeder, so without this wait
# the first COPY in 02-seed.sql runs against an empty directory and fails.
#
# This wrapper:
#   1. Waits up to SEED_WAIT_SECONDS for the CSVs to appear
#   2. Execs the real entrypoint, which then runs 01-schema.sql and 02-seed.sql
#      against a non-empty /seed
#
# On a re-run (database volume already initialised) the entrypoint short-
# circuits and the wait is harmless -- the CSVs are still in the volume.
set -eu

: "${SEED_WAIT_SECONDS:=120}"

required=(
  customers.csv
  products.csv
  orders.csv
  order_items.csv
  inventory_ledger.csv
)

deadline=$(( $(date +%s) + SEED_WAIT_SECONDS ))
while :; do
  if [ -d /seed ]; then
    missing=0
    for f in "${required[@]}"; do
      [ -s "/seed/$f" ] || missing=1
    done
    [ "$missing" = 0 ] && break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "wait-seed.sh: CSVs never appeared in /seed after ${SEED_WAIT_SECONDS}s" >&2
    echo "   expected: ${required[*]}" >&2
    echo "   is the seeder service running?" >&2
    exit 1
  fi
  sleep 2
done

# Hand off to the official entrypoint. The image's ENTRYPOINT is preserved by
# Compose, but the command override is what we actually want to control; this
# wrapper is the entrypoint.
exec docker-entrypoint.sh "$@"
