#!/usr/bin/env bash
# Tear the testbed down.
#
# Usage:
#   down.sh              stop containers, keep volumes (database survives)
#   down.sh --volumes    also delete volumes (database and metrics history)
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

VOLUMES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --volumes) VOLUMES=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$ROOT/.env" ] || { echo "error: .env is missing" >&2; exit 2; }
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

# Compose interpolates APP_IMAGE (declared `:?` in the compose file) even
# for `down`. Export a placeholder so teardown works whether or not an app
# was named, mirroring up.sh.
export APP_IMAGE="${APP_IMAGE:-bench/none:latest}"

ARGS=(--env-file "$ROOT/.env"
      --profile single --profile db --profile app
      --profile loadgen --profile telemetry down --remove-orphans)

if [ "$VOLUMES" = 1 ]; then
  echo "This deletes the seeded database and all recorded metrics history."
  printf 'Type "delete" to confirm: '
  read -r reply
  [ "$reply" = delete ] || { echo "aborted"; exit 1; }
  ARGS+=(--volumes)
fi

if [ "${BENCH_MODE:-single}" = distributed ]; then
  for host in "${BENCH_LOAD_HOST:-}" "${BENCH_APP_HOST:-}" "${BENCH_DB_HOST:-}"; do
    [ -n "$host" ] || continue
    echo "==> down on $host"
    DOCKER_HOST="ssh://$host" docker compose "${ARGS[@]}"
  done
else
  docker compose "${ARGS[@]}"
fi
