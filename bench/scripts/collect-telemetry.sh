#!/usr/bin/env bash
# Query Prometheus for the trial's telemetry and archive it into the
# trial directory.
#
# The benchmark's telemetry is the Prometheus TSDB: it holds the
# framework's /metrics histogram (scraped on bench_telemetry), the
# host conditions (node-exporter), the per-container resource usage
# (cAdvisor), and the database statistics (postgres-exporter). The
# k6 client-side metrics live in the load generator's --summary-export
# output and in the k6-summary.json the trial driver already copied
# into the trial dir; this collector grabs the shared, cross-source
# view that Prometheus unifies.
#
# Usage:
#   collect-telemetry.sh <trial-dir> <start-unix> <end-unix>
#
# The start/end are epoch seconds (or ISO-8601) bounding the
# saturation window. The trial driver knows these; the operator can
# also pass them from the manifest's saturation.started_at/ended_at.
#
# Environment:
#   PROMETHEUS_URL (default http://127.0.0.1:9090)
set -euo pipefail

[ $# -ge 3 ] || {
  echo "usage: $0 <trial-dir> <start> <end>" >&2
  echo "  start/end are epoch seconds or ISO-8601" >&2
  exit 2
}

TRIAL_DIR="$1"
START="$2"
END="$3"
PROM="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

# The series the dashboards plot, grouped so the output file is
# readable. Each entry is a query string used verbatim against the
# Prometheus range API.
QUERIES=(
  # App /metrics histogram, per workload. This is the framework's own
  # server-side view, normalized by the benchmark's recording rule.
  "bench:app:http_request_duration:p99:rate1m"
  # k6 throughput, if the load generator pushed via remote-write.
  "k6_http_reqs_total"
  # Container resource usage for the app and db.
  "rate(container_cpu_usage_seconds_total{name=~'bench-app|bench-db'}[1m])"
  "container_memory_rss{name=~'bench-app|bench-db'}"
  # Host pressure-stall and steal time (reveals a non-isolated testbed).
  "bench:host:cpu_stealtime_p99:rate5s"
  "bench:host:psi_cpu_some_p99"
  # Database connections and TPS.
  "bench:db:active_connections"
  "bench:db:tps:rate1m"
)

mkdir -p "$TRIAL_DIR/telemetry"

# Convert start/end to ISO-8601 for the Prometheus API. If the caller
# passed epoch seconds, convert; if ISO-8601, pass through.
to_rfc3339() {
  case "$1" in
    *[-:]) echo "$1" ;;  # already ISO-ish
    [0-9]*) date -u -d "@$1" +%FT%TZ 2>/dev/null || echo "$1" ;;
    *) echo "$1" ;;
  esac
}
START_RFC="$(to_rfc3339 "$START")"
END_RFC="$(to_rfc3339 "$END")"

echo "telemetry: $PROM [$START_RFC .. $END_RFC]"
echo "        -> $TRIAL_DIR/telemetry/"
echo

for q in "${QUERIES[@]}"; do
  # Derive a filesystem-safe filename from the PromQL expression.
  # The expression may contain punctuation; map all non-alnum/underscore
  # to underscore, collapse, and cap the length.
  name=$(python3 -c "
import re, sys
s = sys.argv[1]
s = re.sub(r'[^A-Za-z0-9_]', '_', s)
s = re.sub(r'_+', '_', s).strip('_')
print(s[:80])
" "$q")
  url="$PROM/api/v1/query_range"
  out="$TRIAL_DIR/telemetry/${name}.json"
  if ! curl -fsS -G "$url" \
    --data-urlencode "query=$q" \
    --data-urlencode "start=$START_RFC" \
    --data-urlencode "end=$END_RFC" \
    --data-urlencode "step=1s" \
    -o "$out" 2>/dev/null; then
    echo "  [skip] $q (no data)" >&2
    rm -f "$out"
    continue
  fi
  # Validate the response is a successful Prometheus response.
  if ! python3 -c "import json,sys; d=json.load(open('$out')); sys.exit(0 if d.get('status')=='success' else 1)" 2>/dev/null; then
    echo "  [warn] $q returned non-success" >&2
    rm -f "$out"
    continue
  fi
  echo "  [ok]   $q"
done

echo
echo "telemetry archived: $(ls -1 "$TRIAL_DIR/telemetry"/*.json 2>/dev/null | wc -l) series"
