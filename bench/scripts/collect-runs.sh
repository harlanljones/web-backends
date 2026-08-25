#!/usr/bin/env bash
# Copy a trial's k6 artifacts from the loadgen-runs volume to the
# host filesystem so the run manifest can reference them.
#
# Usage:
#   collect-runs.sh <trial-id> [<trial-id> ...]
#
# Files are written to ./runs/<trial-id>/. The trial-id argument is
# usually the same one the operator passed to run-trial.sh; the script
# does not need to know about it because the k6 output.js names the
# files with a timestamp prefix and the trial directory is the caller's
# responsibility.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

if [ $# -lt 1 ]; then
  echo "usage: $0 <trial-id> [trial-id ...]" >&2
  exit 2
fi

# Make sure the loadgen is up so the volume is mounted somewhere.
if ! docker ps --format '{{.Names}}' | grep -q '^bench-load$'; then
  echo "bench-load is not running; cannot collect" >&2
  exit 1
fi

DEST="$ROOT/runs"
mkdir -p "$DEST"

for trial_id in "$@"; do
  out="$DEST/$trial_id"
  mkdir -p "$out"
  # Copy the most recent k6 summary files out. We don't filter by
  # trial id here because the timestamp in the filename is what
  # identifies a run; the caller has the timestamp from when they
  # invoked run-trial.sh.
  docker cp bench-load:/runs/. "$out/" 2>&1 | tail -1
  # Fix up ownership -- the files are written by uid 12345 inside
  # the loadgen container; copy from root@bench-load and they'll be
  # owned by root on the host. Trial operators on shared hosts may
  # want a different default; chown to the invoking user is the
  # polite thing to do.
  if [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$out" 2>/dev/null || true
  fi
  echo "trial artifacts -> $out"
done
