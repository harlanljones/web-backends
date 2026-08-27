#!/usr/bin/env bash
# Run a benchmark campaign: N saturation trials per framework, and a
# burn-in trial that is discarded.
#
# The project's experimental design:
#   * three-minute warm-up at 20% target load
#   * ten-minute incremental ramp 500 -> 10,000 RPS
#   * ten-minute steady-state saturation
#   * five independent trials; discard the burn-in run and aggregate the
#     remaining (four) trials with 95% confidence intervals
#
# This script runs the saturation phase for each trial and retains the
# telemetry and system logs alongside the k6 summary. The framework's
# app container must already be up (see run-trial.sh) OR the script
# brings the default framework up.
#
# Usage:
#   run-campaign.sh <framework> [--trials 4] [--burn-in 1] [--label <name>]
#
#   --trials   number of SATURATION trials to measure (default 4)
#   --burn-in  number of WARM-UP trials to discard (default 1)
#   --label    a short campaign identifier for the trial-id prefix.
#              Defaults to <framework>-<YYYY-MM-DD>.
#
# The five-trial design means --trials 4 --burn-in 1 (four measured,
# one discarded). Set --trials 2 --burn-in 0 for a quicksave run.
#
# Environment (in .env):
#   TARGET_RPS, WARMUP_DURATION, RAMP_DURATION, SATURATION_DURATION,
#   RAMP_START_RPS, RAMP_END_RPS, RAMP_STAGES
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

[ $# -ge 1 ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

FRAMEWORK="$1"; shift
TRIALS=4
BURN_IN=1
LABEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --trials)  shift; TRIALS="${1:?--trials needs a number}" ;;
    --burn-in) shift; BURN_IN="${1:?--burn-in needs a number}" ;;
    --label)   shift; LABEL="${1:?--label needs a name}" ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$ROOT/.env" ] || { echo "error: .env is missing" >&2; exit 2; }
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

# ---------------------------------------------------------------------------
# Ensure the testbed and app are up.
# ---------------------------------------------------------------------------
echo "==> campaign setup"
docker ps --format '{{.Names}}' | grep -q '^bench-db$'   || { echo "bench-db not running; start with bench/scripts/up.sh" >&2; exit 2; }
docker ps --format '{{.Names}}' | grep -q '^bench-load$' || { echo "bench-load not running" >&2; exit 2; }
if ! docker ps --format '{{.Names}}' | grep -q '^bench-app$'; then
  echo "bench-app not running; bringing up default framework"
  "$ROOT/bench/scripts/run-trial.sh" "$FRAMEWORK" --keep &
  # run-trial.sh blocks on sleep infinity after ready; we can't easily
  # wait for health here, so poll.
  for _ in $(seq 1 90); do
    if curl -fsS --max-time 1 "http://127.0.0.1:${APP_PORT:-8080}/health" >/dev/null 2>&1; then
      echo "bench-app is ready"; break
    fi
    sleep 1
  done
else
  echo "bench-app already running"
fi

# ---------------------------------------------------------------------------
# Trial naming. A campaign is "one framework, N measured trials".
# Trial-0 is the burn-in; trials 1..N are measured.
# ---------------------------------------------------------------------------
DEFAULT_LABEL="${FRAMEWORK}-$(date +%Y-%m-%d)"
LABEL="${LABEL:-$DEFAULT_LABEL}"
TOTAL=$((TRIALS + BURN_IN))
echo "campaign: framework=$FRAMEWORK trials=$TRIALS burn_in=$BURN_IN label=$LABEL"
echo

for ((i = 0; i < TOTAL; i++)); do
  if [ "$i" -lt "$BURN_IN" ]; then
    role="burnin"
    trial_id="${LABEL}-trial-${i}-burnin"
  else
    role="measure"
    trial_id="${LABEL}-trial-${i}"
  fi

  echo
  echo "================================================================"
  echo "trial $i/$((TOTAL-1)): $role ($trial_id)"
  echo "================================================================"

  # Reset pg_stat_statements before each trial so the per-trial query
  # profile is attributed cleanly.
  docker exec bench-db psql -U "${POSTGRES_USER:-bench}" -d "${POSTGRES_DB:-bench}" \
    -c "SELECT pg_stat_statements_reset();" >/dev/null 2>&1

  # Run the trial. exec-trial.sh handles warmup+ramp+saturation with
  # per-phase archival. We pass the same env overrides through.
  t0=$(date +%s)
  if ! "$ROOT/bench/scripts/exec-trial.sh" "$trial_id" \
      --phases "${CAMPAIGN_PHASES:-warmup,ramp,saturation}" >/dev/null 2>&1; then
    echo "  [warn] trial returned non-zero (see runs/$trial_id/ for the log)" >&2
    # Non-zero from exec-trial means a phase failed its thresholds. The
    # trial dir is still valid, so continue -- the analysis step decides
    # whether to discard.
  fi
  t1=$(date +%s)
  echo "  trial $i elapsed: $((t1 - t0))s"

  # Collect telemetry over the saturation window. Parse the manifest's
  # saturation start/end.
  TRIAL_DIR="$ROOT/runs/$trial_id"
  if [ -f "$TRIAL_DIR/manifest.json" ]; then
    SAT_START=$(python3 -c "
import json, os
m = json.load(open('$TRIAL_DIR/manifest.json'))
s = (m.get('saturation') or {}).get('started_at')
print(s or '')" 2>/dev/null)
    SAT_END=$(python3 -c "
import json, os
m = json.load(open('$TRIAL_DIR/manifest.json'))
s = (m.get('saturation') or {}).get('ended_at')
print(s or '')" 2>/dev/null)
    if [ -n "$SAT_START" ] && [ -n "$SAT_END" ]; then
      echo "  collecting telemetry [$SAT_START .. $SAT_END]"
      "$ROOT/bench/scripts/collect-telemetry.sh" "$TRIAL_DIR" "$SAT_START" "$SAT_END" >/dev/null 2>&1 \
        || echo "  [warn] telemetry collection reported issues"
    else
      echo "  [skip] no saturation window recorded in manifest"
    fi
  else
    echo "  [warn] no manifest at $TRIAL_DIR"
  fi

  # Retain system logs for the trial (app, db, loadgen, prometheus).
  mkdir -p "$TRIAL_DIR/logs"
  for svc in bench-app bench-db bench-load bench-prometheus bench-grafana; do
    if docker ps --format '{{.Names}}' | grep -q "^$svc$"; then
      docker logs --since "${t0}s" "$svc" > "$TRIAL_DIR/logs/$svc.log" 2>&1 || true
    fi
  done

  # A real measurement run needs the k6 artifacts to be present; log a
  # summary line for the operator.
  echo "  artifacts: $(ls -1 "$TRIAL_DIR"/*/k6-summary.json 2>/dev/null | wc -l) phase summary(ies), $(ls -1 "$TRIAL_DIR"/telemetry/*.json 2>/dev/null | wc -l) telemetry series"
done

echo
echo "campaign complete: framework=$FRAMEWORK trials=$TRIALS (+) burn_in=$BURN_IN"
echo "artifacts under: $ROOT/runs/$LABEL-trial-*/"
echo "review each manifest and run bench/scripts/verify-manifest.sh before publishing"
