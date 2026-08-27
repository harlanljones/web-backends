#!/usr/bin/env bash
# Build and run a single trial.
#
# Usage:
#   run-trial.sh <framework>                  # build, start, stop after
#   run-trial.sh <framework> --keep           # leave the app running
#   run-trial.sh <framework> --rebuild        # force a fresh image build
#   run-trial.sh --list                       # print registered frameworks
#   run-trial.sh <framework> --no-build       # use the existing image
#
# The script is intentionally short. The trial protocol (warm-up, ramp,
# saturation) lives in the k6 scripts and the run-trial.sh orchestration
# only wires the app to the database.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

[ $# -ge 1 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

case "$1" in
  --list|-l)
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$ROOT/bench/frameworks.yaml'))
for f in data.get('frameworks', []):
    print(f'{f[\"name\"]:12s} {f[\"image\"]:32s} workloads={f[\"workloads\"]}')" 2>/dev/null || \
    awk '/^[ \t]*- name:/ { if(name && image) print name, image; name=$3; image="" }
         /^[ \t]*image:/ { image=$2 }
         END { if(name && image) print name, image }' "$ROOT/bench/frameworks.yaml"
    exit 0
    ;;
esac

FRAMEWORK="$1"; shift
REBUILD=0
KEEP=0
NO_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild)   REBUILD=1 ;;
    --keep)      KEEP=1 ;;
    --no-build)  NO_BUILD=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Resolve the framework entry. A simple grep-based parser because the file is
# 30 lines and the real parser is the conformance runner's job.
# ---------------------------------------------------------------------------
SECTION=$(awk "/^[[:space:]]*- name: ${FRAMEWORK}\$/,/^[[:space:]]*- name: /" "$ROOT/bench/frameworks.yaml" \
  | sed '/^[[:space:]]*- name: /!b' | head -1)
if [ -z "$SECTION" ]; then
  echo "framework '$FRAMEWORK' is not registered in bench/frameworks.yaml" >&2
  echo "registered:" >&2
  awk '/^ *- name:/ { print "  " $3 }' "$ROOT/bench/frameworks.yaml" >&2
  exit 2
fi

IMAGE=$(awk -v fw="$FRAMEWORK" '
  $0 ~ "^[ \t]*- name: " fw "[ \t]*$" {found=1; next}
  found && /image:/ {gsub(/"/,"",$2); print $2; exit}
' "$ROOT/bench/frameworks.yaml")
DOCKERFILE=$(awk -v fw="$FRAMEWORK" '
  $0 ~ "^[ \t]*- name: " fw "[ \t]*$" {found=1; next}
  found && /dockerfile:/ {gsub(/"/,"",$2); print $2; exit}
' "$ROOT/bench/frameworks.yaml")

echo "framework: $FRAMEWORK"
echo "image:     $IMAGE"
echo "dockerfile:$DOCKERFILE"
echo

# ---------------------------------------------------------------------------
# Build the image (unless --no-build). The build context is the framework's
# directory, not the repo root -- a framework's Dockerfile is not interested
# in the contracts or bench/ trees.
# ---------------------------------------------------------------------------
if [ "$NO_BUILD" = 0 ] && { [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; }; then
  CONTEXT="$(dirname "$ROOT/$DOCKERFILE")"
  echo "==> building $IMAGE from $CONTEXT"
  docker build --tag "$IMAGE" --file "$ROOT/$DOCKERFILE" "$CONTEXT"
fi

# ---------------------------------------------------------------------------
# Ensure the rest of the testbed is up. The seeder has already run on a
# fresh volume, so the database is seeded; we only need to bring the
# non-app services up.
# ---------------------------------------------------------------------------
[ -f "$ROOT/.env" ] || { echo "error: .env is missing" >&2; exit 2; }
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

# Compose interpolates APP_IMAGE (declared `:?`) even for profiles that do
# not include the app. Export a placeholder until the real image is chosen
# below, so the non-app testbed can be reconciled first.
export APP_IMAGE="${APP_IMAGE:-bench/none:latest}"

echo "==> ensuring testbed is up (excluding app)"
DOCKER_HOST_REAL="${DOCKER_HOST:-}"
if [ "${BENCH_MODE:-single}" = distributed ]; then
  : "${BENCH_DB_HOST:?set BENCH_DB_HOST for distributed mode}"
  DOCKER_HOST="ssh://$BENCH_DB_HOST" \
    docker compose --env-file "$ROOT/.env" --profile db --profile telemetry up -d
  DOCKER_HOST="ssh://$BENCH_LOAD_HOST" \
    docker compose --env-file "$ROOT/.env" --profile loadgen up -d
  DOCKER_HOST="$DOCKER_HOST_REAL"
else
  docker compose --env-file "$ROOT/.env" \
    --profile db --profile telemetry --profile loadgen up -d
fi

# Wait for the database to be healthy. The trial cannot start until
# pg_isready succeeds.
echo "==> waiting for the database to be healthy"
for _ in $(seq 1 60); do
  state=$(docker inspect -f '{{.State.Health.Status}}' bench-db 2>/dev/null || echo missing)
  if [ "$state" = healthy ]; then break; fi
  sleep 2
done
[ "$state" = healthy ] || { echo "database did not become healthy: $state" >&2; exit 1; }

# Reset pg_stat_statements so the trial's counters start clean. This is
# not the framework's responsibility; the driver does it.
docker exec bench-db psql -U "${POSTGRES_USER:-bench}" -d "${POSTGRES_DB:-bench}" \
  -c "SELECT pg_stat_statements_reset();" >/dev/null

# ---------------------------------------------------------------------------
# Start the application under test. APP_IMAGE is the contract the compose
# file reads; setting it here means the operator does not have to.
# ---------------------------------------------------------------------------
echo "==> starting $IMAGE as bench-app"
export APP_IMAGE="$IMAGE"

if [ "${BENCH_MODE:-single}" = distributed ]; then
  : "${BENCH_APP_HOST:?set BENCH_APP_HOST for distributed mode}"
  DOCKER_HOST="ssh://$BENCH_APP_HOST" \
    docker compose --env-file "$ROOT/.env" --profile app up -d
else
  docker compose --env-file "$ROOT/.env" --profile app up -d
fi

# Wait for /health to return 200. Compose's healthcheck handles "the
# process is up"; we additionally want "the database is reachable and the
# /health endpoint is wired correctly".
echo "==> waiting for /health"
ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 1 "http://127.0.0.1:${APP_PORT:-8080}/health" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
[ "$ready" = 1 ] || {
  echo "app did not become ready; last 50 lines of logs:" >&2
  docker logs --tail 50 bench-app >&2 || true
  exit 1
}

# Reset pg_stat_statements once more, after the application is warm and
# has done its first round of planning. The first reset captured a cold
# planner; the second one captures the steady state.
docker exec bench-db psql -U "${POSTGRES_USER:-bench}" -d "${POSTGRES_DB:-bench}" \
  -c "SELECT pg_stat_statements_reset();" >/dev/null

echo
echo "trial ready: $IMAGE is up at http://127.0.0.1:${APP_PORT:-8080}"
echo
echo "Run the k6 protocol:"
echo "  # full three-phase trial with per-phase archival into runs/<trial>/"
echo "  bench/scripts/exec-trial.sh <trial-id>"
echo
echo "  # or one phase at a time, in another terminal"
echo "  docker exec bench-load k6 run /scripts/warmup.js"
echo "  docker exec bench-load k6 run /scripts/ramp.js"
echo "  docker exec bench-load k6 run /scripts/saturation.js"
echo
echo "See bench/k6/README.md for the protocol and env variables."
echo

if [ "$KEEP" = 0 ]; then
  trap 'echo "==> stopping bench-app"; docker compose --env-file "$ROOT/.env" --profile app down --remove-orphans >/dev/null 2>&1 || true' EXIT
  echo "(press Ctrl-C to stop the app; --keep leaves it running)"
  # Block forever so the operator can attach a k6 run to this shell.
  sleep infinity
fi
