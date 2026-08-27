#!/usr/bin/env bash
# Execute a benchmark trial: warmup -> ramp -> saturation, with
# per-phase output captured into runs/<trial-id>/.
#
# Usage:
#   exec-trial.sh <trial-id>
#   exec-trial.sh <trial-id> --skip-warmup
#   exec-trial.sh <trial-id> --skip-ramp
#   exec-trial.sh <trial-id> --phases warmup,saturation
#
# Assumptions:
#   - The testbed is up (`bench/scripts/up.sh` already ran)
#   - The application is up (a `run-trial.sh <framework>` already
#     brought it to /health=200)
#   - The loadgen is reachable as `bench-load`
#
# The script orchestrates the three k6 phases back-to-back. Each phase
# runs as a separate k6 invocation so its threshold logic is scoped
# to the phase (warmup and ramp have no thresholds; saturation does).
# Per-phase output lands in /runs inside the loadgen container; the
# script moves it into runs/<trial-id>/<phase>/ on the host.
#
# Environment overrides for the k6 phases (set in .env or in the
# calling environment):
#   TARGET_RPS, WARMUP_DURATION, RAMP_DURATION, RAMP_START_RPS,
#   RAMP_END_RPS, RAMP_STAGES, SATURATION_DURATION
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

[ $# -ge 1 ] || { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

TRIAL_ID="$1"; shift
PHASES="warmup,ramp,saturation"
SKIP_WARMUP=0
SKIP_RAMP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-warmup)     SKIP_WARMUP=1 ;;
    --skip-ramp)       SKIP_RAMP=1 ;;
    --phases) shift; PHASES="${1:?--phases needs comma-separated list}" ;;
    -h|--help)         sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ "$SKIP_WARMUP" = 1 ] && PHASES="${PHASES//warmup,}"
[ "$SKIP_RAMP" = 1 ]   && PHASES="${PHASES//ramp,}"
PHASES="${PHASES#,}"
PHASES="${PHASES%,}"
[ -n "$PHASES" ] || { echo "no phases selected" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Sanity checks. The orchestration is only valid if the testbed, app,
# and loadgen are all up.
# ---------------------------------------------------------------------------
[ -f "$ROOT/.env" ] || { echo "error: .env is missing" >&2; exit 2; }
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

docker ps --format '{{.Names}}' | grep -q '^bench-db$'   || { echo "bench-db is not running" >&2; exit 2; }
docker ps --format '{{.Names}}' | grep -q '^bench-app$'  || { echo "bench-app is not running" >&2; exit 2; }
docker ps --format '{{.Names}}' | grep -q '^bench-load$' || { echo "bench-load is not running" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Output directory. The trial-id is the operator's convention; we
# create runs/<trial-id>/<phase>/ here and let k6 write into /runs/
# (the named volume) then we copy out.
# ---------------------------------------------------------------------------
RUNS_HOST="$ROOT/runs"
TRIAL_DIR="$RUNS_HOST/$TRIAL_ID"
mkdir -p "$TRIAL_DIR"

# Record trial metadata up front. The k6 outputs fill in their slots
# as each phase completes. The framework image is read from the running
# bench-app container (authoritative: it is what is actually under test),
# falling back to APP_IMAGE when the app has already stopped.
FRAMEWORK_IMAGE="$(docker inspect -f '{{.Config.Image}}' bench-app 2>/dev/null || true)"
FRAMEWORK_IMAGE="${FRAMEWORK_IMAGE:-${APP_IMAGE:-unknown}}"
python3 - <<EOF > "$TRIAL_DIR/manifest.json.tmp"
import json
phases = "$PHASES".split(",")
print(json.dumps({
    "trial_id": "$TRIAL_ID",
    "started_at": "$(date -Iseconds)",
    "framework_image": "$FRAMEWORK_IMAGE",
    "phases": phases,
    "config": {
        "target_rps": int("${TARGET_RPS:-10000}"),
        "warmup_duration": "${WARMUP_DURATION:-3m}",
        "warmup_rps_frac": float("${WARMUP_RPS_FRAC:-0.2}"),
        "ramp_duration": "${RAMP_DURATION:-10m}",
        "ramp_start_rps": int("${RAMP_START_RPS:-500}"),
        "ramp_end_rps": int("${RAMP_END_RPS:-10000}"),
        "ramp_stages": int("${RAMP_STAGES:-10}"),
        "saturation_duration": "${SATURATION_DURATION:-10m}",
        "workloads": "${WORKLOADS:-json,product_read,order_write,dashboard}".split(","),
        "app_cores": int("${APP_CPUS:-4}")
    }
}, indent=2))
EOF
mv "$TRIAL_DIR/manifest.json.tmp" "$TRIAL_DIR/manifest.json"

echo "trial: $TRIAL_ID"
echo "phases: $PHASES"
echo "out:    $TRIAL_DIR"
echo

# ---------------------------------------------------------------------------
# Preflight. Capture host conditions at trial time so a reader can
# audit the testbed the trial actually ran on, not the testbed the
# operator thought they were running on. Three roles, one host each
# in distributed mode, all three on one host in single mode.
#
# Preflight exit code is recorded in the manifest, not used to
# block the trial. A failed preflight is exactly the kind of
# evidence the run manifest exists to capture; the run is allowed
# to proceed so the post-mortem has data to work with.
# ---------------------------------------------------------------------------
echo "==> recording preflight"
preflight_failed=0
if [ "${BENCH_MODE:-single}" = distributed ]; then
  : "${BENCH_DB_HOST:?set BENCH_DB_HOST in .env}"
  : "${BENCH_APP_HOST:?set BENCH_APP_HOST in .env}"
  : "${BENCH_LOAD_HOST:?set BENCH_LOAD_HOST in .env}"
  ssh "$BENCH_APP_HOST"  "cat > /tmp/preflight.sh"  < "$ROOT/bench/scripts/preflight.sh"
  ssh "$BENCH_DB_HOST"   "cat > /tmp/preflight.sh"  < "$ROOT/bench/scripts/preflight.sh"
  ssh "$BENCH_LOAD_HOST" "cat > /tmp/preflight.sh"  < "$ROOT/bench/scripts/preflight.sh"
  BENCH_ROLE=app      ssh "$BENCH_APP_HOST"  "bash /tmp/preflight.sh --json"  > "$TRIAL_DIR/preflight-app.json"      || preflight_failed=$((preflight_failed+1))
  BENCH_ROLE=db       ssh "$BENCH_DB_HOST"   "bash /tmp/preflight.sh --json"  > "$TRIAL_DIR/preflight-db.json"       || preflight_failed=$((preflight_failed+1))
  BENCH_ROLE=loadgen  ssh "$BENCH_LOAD_HOST" "bash /tmp/preflight.sh --json"  > "$TRIAL_DIR/preflight-loadgen.json"  || preflight_failed=$((preflight_failed+1))
else
  BENCH_ROLE=app      bash "$ROOT/bench/scripts/preflight.sh" --json > "$TRIAL_DIR/preflight-app.json"      || preflight_failed=$((preflight_failed+1))
  BENCH_ROLE=db       bash "$ROOT/bench/scripts/preflight.sh" --json > "$TRIAL_DIR/preflight-db.json"       || preflight_failed=$((preflight_failed+1))
  BENCH_ROLE=loadgen  bash "$ROOT/bench/scripts/preflight.sh" --json > "$TRIAL_DIR/preflight-loadgen.json"  || preflight_failed=$((preflight_failed+1))
fi
echo "preflight: $preflight_failed of 3 host(s) reported failures (see preflight-*.json)"

# ---------------------------------------------------------------------------
# Run each phase. Each phase is a separate k6 invocation; the
# threshold logic of one phase cannot pollute the next.
# ---------------------------------------------------------------------------
phase_start() {
  local phase="$1"
  echo
  echo "==> $phase starting at $(date -Iseconds)"
  date -Iseconds > "$TRIAL_DIR/$phase.started_at"
}

phase_end() {
  local phase="$1"
  local status="$2"
  date -Iseconds > "$TRIAL_DIR/$phase.ended_at"
  echo "==> $phase finished at $(date -Iseconds) (status=$status)"
}

run_phase() {
  local phase="$1"
  local script="/scripts/${phase}.js"
  local env_args=(
    # k6 runs INSIDE the loadgen container, so the target is the app's
    # service name on bench_edge (`app`), not the host loopback. In
    # distributed mode BENCH_APP_HOST is the app node's private IP.
    -e TARGET_BASE_URL="http://${BENCH_APP_HOST:-app}:8080"
    -e TARGET_RPS="${TARGET_RPS:-10000}"
    -e WORKLOADS="${WORKLOADS:-json,product_read,order_write,dashboard}"
  )
  case "$phase" in
    warmup)
      env_args+=( -e WARMUP_DURATION="${WARMUP_DURATION:-3m}" )
      ;;
    ramp)
      env_args+=( -e RAMP_DURATION="${RAMP_DURATION:-10m}" )
      env_args+=( -e RAMP_START_RPS="${RAMP_START_RPS:-500}" )
      env_args+=( -e RAMP_END_RPS="${RAMP_END_RPS:-10000}" )
      env_args+=( -e RAMP_STAGES="${RAMP_STAGES:-10}" )
      ;;
    saturation)
      env_args+=( -e SATURATION_DURATION="${SATURATION_DURATION:-10m}" )
      ;;
    *)
      echo "unknown phase: $phase" >&2
      return 2
      ;;
  esac

  phase_start "$phase"
  # Use a stable filename for the k6 summary so we know which file
  # belongs to which phase. The timestamp would also work, but the
  # k6 handleSummary() path includes a timestamp prefix that is the
  # trial wall-clock time; the phase we already know.
  local k6_status=0
  docker exec bench-load k6 run \
    --summary-export="/runs/${TRIAL_ID}-${phase}.json" \
    "${env_args[@]}" \
    "$script" 2>&1 | tee "$TRIAL_DIR/${phase}.log" || k6_status=$?
  phase_end "$phase" "$k6_status"

  # The loadgen /runs/ now has <trial>-<phase>.json (via --summary-export)
  # plus the timestamp-prefixed summary.{json,txt} from handleSummary().
  # We grab the timestamped ones (which include the text rendering)
  # and rename them.
  local latest_json latest_txt
  latest_json=$(docker exec bench-load ls -t /runs/ 2>/dev/null \
    | grep -E '[0-9]+Z-summary\.json$' | head -1)
  latest_txt=$(docker exec bench-load ls -t /runs/ 2>/dev/null \
    | grep -E '[0-9]+Z-summary\.txt$' | head -1)

  if [ -n "$latest_json" ]; then
    docker cp "bench-load:/runs/$latest_json" "$TRIAL_DIR/${phase}/k6-summary.json"
  fi
  if [ -n "$latest_txt" ]; then
    docker cp "bench-load:/runs/$latest_txt"  "$TRIAL_DIR/${phase}/k6-summary.txt"
  fi

  # Always grab the explicit --summary-export file as well; that
  # one is guaranteed to be named for this phase, so it is the
  # authoritative one.
  docker cp "bench-load:/runs/${TRIAL_ID}-${phase}.json" \
    "$TRIAL_DIR/${phase}/k6-export.json" 2>/dev/null || true

  return $k6_status
}

# Re-read the manifest so the operator can see what's in flight.
echo "config:"
python3 -c "import json,sys; m=json.load(open('$TRIAL_DIR/manifest.json')); print(json.dumps(m['config'], indent=2))"

# Build the per-phase subdirectories up front so the failure path can
# always find them.
IFS=',' read -ra PHASE_LIST <<< "$PHASES"
for p in "${PHASE_LIST[@]}"; do
  mkdir -p "$TRIAL_DIR/$p"
done

trial_status=0
for phase in "${PHASE_LIST[@]}"; do
  if ! run_phase "$phase"; then
    trial_status=$?
    echo "phase $phase failed (status=$trial_status); continuing with remaining phases" >&2
  fi
done

# ---------------------------------------------------------------------------
# pg_stat_statements snapshot. Captured at trial end so the
# aggregate per-trial query profile is recorded alongside the k6
# output. The trial driver resets pg_stat_statements at the start of
# every trial; this snapshot is what the trial produced.
# ---------------------------------------------------------------------------
echo
echo "==> capturing pg_stat_statements"
docker exec bench-db psql -U "${POSTGRES_USER:-bench}" -d "${POSTGRES_DB:-bench}" \
  -c "SELECT query, calls, total_exec_time, mean_exec_time, rows
      FROM pg_stat_statements
      ORDER BY total_exec_time DESC
      LIMIT 100" \
  --csv --pset footer=off > "$TRIAL_DIR/pg_stat_statements.csv" 2>/dev/null || \
  echo "pg_stat_statements capture failed" >&2

# ---------------------------------------------------------------------------
# Telemetry. If a saturation phase ran, archive its Prometheus window
# so the measurement's metrics are retained alongside the k6 summary.
# The k6 summary holds the client-side view; Prometheus holds the
# server-side and host view (the framework /metrics histogram, the
# container CPU/memory, and the host pressure-stall information).
# ---------------------------------------------------------------------------
if [[ ",$PHASES," == *",saturation,"* ]]; then
  echo "==> capturing telemetry"
  # Read the phase's wall-clock files, which exist at this point. The
  # manifest's saturation block is only written in the final update
  # below, so it cannot be used here.
  SAT_START="$(cat "$TRIAL_DIR/saturation.started_at" 2>/dev/null || true)"
  SAT_END="$(cat "$TRIAL_DIR/saturation.ended_at" 2>/dev/null || true)"
  if [ -n "$SAT_START" ] && [ -n "$SAT_END" ]; then
    "$ROOT/bench/scripts/collect-telemetry.sh" "$TRIAL_DIR" "$SAT_START" "$SAT_END" 2>&1 \
      | sed 's/^/    /' || echo "    (telemetry issues, see above)"
  else
    echo "    (no saturation window recorded; skipping telemetry)"
  fi
fi

# Final manifest update with completion time.
python3 - <<EOF > "$TRIAL_DIR/manifest.json.tmp"
import json, os
m = json.load(open("$TRIAL_DIR/manifest.json"))
m["ended_at"] = "$(date -Iseconds)"
m["status"] = $trial_status
m["preflight_failed"] = $preflight_failed
m["phases_run"] = "$PHASES".split(",")
trial_dir = "$TRIAL_DIR"
for p in m["phases_run"]:
    started_path = os.path.join(trial_dir, f"{p}.started_at")
    ended_path   = os.path.join(trial_dir, f"{p}.ended_at")
    m[p] = {
        "started_at": open(started_path).read().strip() if os.path.exists(started_path) else None,
        "ended_at":   open(ended_path).read().strip()   if os.path.exists(ended_path)   else None,
    }
print(json.dumps(m, indent=2))
EOF
mv "$TRIAL_DIR/manifest.json.tmp" "$TRIAL_DIR/manifest.json"

echo
echo "trial complete: status=$trial_status"
echo "out: $TRIAL_DIR"
exit $trial_status
