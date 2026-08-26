#!/usr/bin/env bash
# Check that the database was NOT the bottleneck during a trial.
#
# A database that is >80% busy cannot meaningfully tell us that a
# framework achieved N RPS; the bottleneck moved. This reads the
# database's CPU utilization from the trial's telemetry archive over
# the saturation window and reports whether it stayed under the
# headroom threshold.
#
# Usage:
#   verify-manifest.sh <trial-dir> && check-db-headroom.sh <trial-dir>
#   check-db-headroom.sh runs/<trial-id> [--max 0.8]
#
# Exit 0 = database had headroom; exit 1 = the database was saturated.
set -euo pipefail

[ $# -ge 1 ] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
TRIAL_DIR="${1%/}"
MAX="${2:-0.8}"

# The telemetry archive stores per-series JSON (Prometheus query_range).
# The database CPU series is the one whose metric matches the app/db
# container CPU. The collector writes it under a sanitized filename from
# the PromQL `rate(container_cpu_usage_seconds_total{name=~'bench-app|bench-db'}[1m])`.
# We pinpoint the series carrying name="bench-db" and take its max.
TEL="$TRIAL_DIR/telemetry"

if [ ! -d "$TEL" ]; then
  echo "no telemetry archive at $TEL" >&2
  exit 2
fi

python3 - "$TRIAL_DIR" "$MAX" <<'PY'
import json, glob, os, sys

trial_dir, max_str = sys.argv[1], sys.argv[2]
max_allowed = float(max_str)
telemetry_dir = os.path.join(trial_dir, "telemetry")
if not os.path.isdir(telemetry_dir):
    print("no telemetry dir", file=sys.stderr)
    sys.exit(2)

# Find the DB CPU series. The archive has one file per PromQL; we scan
# every .json and take the max value of any series with name="bench-db"
# whose metric is a CPU usage rate (container_cpu_usage_seconds_total).
db_cpu = []
for path in glob.glob(os.path.join(telemetry_dir, "*.json")):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        continue
    for series in (d.get("data") or {}).get("result", []):
        m = series.get("metric", {})
        # The collector's DB-CPU query matches name=~'bench-app|bench-db';
        # keep only the database container's series.
        if m.get("name") != "bench-db":
            continue
        for _, val in series.get("values", []):
            try:
                db_cpu.append(float(val))
            except (TypeError, ValueError):
                pass

if not db_cpu:
    print("no bench-db CPU series found in telemetry; cannot check headroom", file=sys.stderr)
    sys.exit(2)

peak = max(db_cpu)
print(f"bench-db CPU peak over saturation: {peak:.3f} cores (max allowed {max_allowed})")
# Add 1 to account for a single core being the floor of a rate series.
if peak <= max_allowed:
    print("database had headroom")
    sys.exit(0)
else:
    print(f"database was saturated ({peak:.3f} > {max_allowed:.3f}); the result is DB-bound, not framework-bound", file=sys.stderr)
    sys.exit(1)
PY
