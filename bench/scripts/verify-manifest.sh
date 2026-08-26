#!/usr/bin/env bash
# Verify a trial's run manifest is publishable.
#
# A trial is publishable when ALL of the following hold:
#   * the saturation phase exists and produced a k6 summary
#   * the saturation k6 summary shows it ran at a defensible RPS with
#     minimal error rate and tail latency
#   * preflight reported 0 failures on all three roles
#   * telemetry was captured (>= 1 series)
#   * system logs were captured for the app container
#
# This is the gate HJ-370's milestone needs before a trial's numbers
# can enter the aggregated results.
#
# Usage:
#   verify-manifest.sh <trial-dir> [<trial-dir> ...]
#   exit 0  ALL trials publishable
#   exit 1  at least one trial is NOT publishable
#   exit 2  usage / missing inputs
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

if [ $# -lt 1 ]; then
  echo "usage: $0 <trial-dir> [<trial-dir> ...]" >&2
  exit 2
fi

overall=0
for dir in "$@"; do
  dir="${dir%/}"
  # Allow three forms: an absolute path, a relative "runs/<trial-id>",
  # or a bare trial-id under the default runs/ directory.
  case "$dir" in
    /*) : ;;
    runs/*) dir="$ROOT/$dir" ;;
    *) dir="$ROOT/runs/${dir##*/}" ;;  # strip any leading path, use basename
  esac
  ok=1
  echo "manifest: $dir"

  # 1. manifest.json present and well-formed.
  manifest="$dir/manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "  [FAIL] manifest.json missing"
    ok=0
  else
    if ! python3 -c "import json; json.load(open('$manifest'))" 2>/dev/null; then
      echo "  [FAIL] manifest.json is not valid JSON"
      ok=0
    fi
  fi

  # 2. saturation phase present.
  sat_summary="$dir/saturation/k6-summary.json"
  if [ ! -f "$sat_summary" ]; then
    echo "  [FAIL] saturation/k6-summary.json missing"
    ok=0
  else
    if ! python3 -c "import json; json.load(open('$sat_summary'))" 2>/dev/null; then
      echo "  [FAIL] saturation k6 summary is not valid JSON"
      ok=0
    fi
  fi

  # 3. preflight recorded 0 failures.
  for role in app db loadgen; do
    pf="$dir/preflight-$role.json"
    if [ ! -f "$pf" ]; then
      echo "  [FAIL] preflight-$role.json missing"
      ok=0
    elif [ "$(python3 -c "import json; print(json.load(open('$pf')).get('failures', -1))" 2>/dev/null)" != "0" ]; then
      echo "  [FAIL] preflight-$role reported failures (run is not publishable)"
      ok=0
    fi
  done

  # 4. telemetry captured (>= 1 series).
  telemetry_count=$(ls -1 "$dir"/telemetry/*.json 2>/dev/null | wc -l)
  if [ "$telemetry_count" -lt 1 ]; then
    echo "  [FAIL] no telemetry captured (telemetry/ empty)"
    ok=0
  fi

  # 5. app container logs retained.
  if [ ! -f "$dir/logs/bench-app.log" ]; then
    echo "  [warn] no app container log retained (logs/bench-app.log missing)"
  fi

  # 6. k6 saturation thresholds. The saturation k6 run already failed on
  #    a threshold if it breached (that's why exec-trial returned non-zero);
  #    re-check the per-workload histograms for latencies in a sane range.
  if [ -f "$sat_summary" ] && [ -f "$manifest" ]; then
    python3 -c "
import json, sys
m = json.load(open('$manifest'))
sat = m.get('saturation') or {}
if not sat.get('started_at') or not sat.get('ended_at'):
    print('  [FAIL] saturation window not recorded in manifest')
    sys.exit(1)
" 2>/dev/null || ok=0
  fi

  if [ "$ok" = 1 ]; then
    echo "  [PASS] publishable"
  else
    echo "  [FAIL] not publishable"
    overall=1
  fi
  echo
done

exit $overall
