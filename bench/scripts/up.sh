#!/usr/bin/env bash
# Bring the testbed up.
#
# Usage:
#   up.sh                       single-host mode, all roles (development)
#   up.sh --mode distributed    one role per host, addressed via DOCKER_HOST
#   up.sh --role db             single role on the current Docker endpoint
#   up.sh --no-app              skip the application (no APP_IMAGE chosen yet)
#
# In distributed mode the DOCKER_HOST endpoints come from .env:
#   BENCH_LOAD_HOST, BENCH_APP_HOST, BENCH_DB_HOST
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

MODE="${BENCH_MODE:-single}"
ROLE=""
WITH_APP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) shift; MODE="${1:?--mode needs single|distributed}" ;;
    --role) shift; ROLE="${1:?--role needs a value}" ;;
    --no-app) WITH_APP=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$ROOT/.env" ]; then
  echo "error: .env is missing. Copy it and set the two passwords:" >&2
  echo "  cp .env.example .env && \$EDITOR .env" >&2
  exit 2
fi

# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

compose() { docker compose --env-file "$ROOT/.env" "$@"; }

if [ -n "$ROLE" ]; then
  compose --profile "$ROLE" up -d
  exit $?
fi

case "$MODE" in
  single)
    # `single` brings up every profile on one host. The application is skipped
    # unless APP_IMAGE is set, because there is no default framework: a trial
    # always names the one it is measuring.
    if [ "$WITH_APP" = 1 ] && [ -n "${APP_IMAGE:-}" ]; then
      compose --profile single up -d
    else
      compose --profile db --profile telemetry --profile loadgen up -d
      echo
      echo "app not started: set APP_IMAGE, or use bench/scripts/run-trial.sh <framework>"
    fi
    ;;
  distributed)
    : "${BENCH_DB_HOST:?set BENCH_DB_HOST in .env for distributed mode}"
    : "${BENCH_APP_HOST:?set BENCH_APP_HOST in .env for distributed mode}"
    : "${BENCH_LOAD_HOST:?set BENCH_LOAD_HOST in .env for distributed mode}"

    echo "==> db + telemetry on $BENCH_DB_HOST"
    DOCKER_HOST="ssh://$BENCH_DB_HOST" compose --profile db --profile telemetry up -d

    echo "==> loadgen on $BENCH_LOAD_HOST"
    DOCKER_HOST="ssh://$BENCH_LOAD_HOST" compose --profile loadgen up -d

    if [ "$WITH_APP" = 1 ] && [ -n "${APP_IMAGE:-}" ]; then
      echo "==> app on $BENCH_APP_HOST"
      DOCKER_HOST="ssh://$BENCH_APP_HOST" compose --profile app up -d
    else
      echo "app not started: use bench/scripts/run-trial.sh <framework>"
    fi
    ;;
  *)
    echo "unknown mode: $MODE (expected single or distributed)" >&2
    exit 2
    ;;
esac

echo
echo "waiting for the database to become healthy"
for _ in $(seq 1 60); do
  state=$(docker inspect -f '{{.State.Health.Status}}' bench-db 2>/dev/null || echo missing)
  [ "$state" = healthy ] && break
  sleep 2
done
docker inspect -f 'bench-db: {{.State.Health.Status}}' bench-db 2>/dev/null || true
