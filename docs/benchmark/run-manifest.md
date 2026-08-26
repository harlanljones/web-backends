# Run manifest

A trial's complete output is a directory under `runs/<trial-id>/` with
the following layout:

```
runs/<trial-id>/
  manifest.json              trial metadata, timing, status
  pg_stat_statements.csv     top-100 queries by total_exec_time
  preflight-app.json         host conditions on the app node at trial time
  preflight-db.json          ... on the database node
  preflight-loadgen.json     ... on the load generator node
  telemetry/                 Prometheus range-query archive over the
                             saturation window (one .json per curated
                             series); empty if no saturation phase ran
  logs/                      docker logs per service at trial time
  warmup/
    k6-summary.json          full k6 metrics tree, warmup phase
    k6-summary.txt           human-readable summary, warmup phase
    k6-export.json           --summary-export output, warmup phase
  warmup.started_at          ISO-8601 timestamp
  warmup.ended_at            ISO-8601 timestamp
  warmup.log                 full k6 stdout+stderr
  ramp/                      same as warmup/
  ramp.started_at, ramp.ended_at, ramp.log
  saturation/                same as warmup/
  saturation.started_at, saturation.ended_at, saturation.log
```

## manifest.json

```json
{
  "trial_id": "2026-08-25-go-trial-1",
  "started_at": "2026-08-25T14:24:18-07:00",
  "ended_at":   "2026-08-25T14:24:37-07:00",
  "framework_image": "bench/go:latest",
  "phases":      ["warmup", "ramp", "saturation"],
  "phases_run":  ["warmup", "ramp", "saturation"],
  "config": {
    "target_rps":          10000,
    "warmup_duration":     "3m",
    "warmup_rps_frac":     0.2,
    "ramp_duration":       "10m",
    "ramp_start_rps":      500,
    "ramp_end_rps":        10000,
    "ramp_stages":         10,
    "saturation_duration": "10m"
  },
  "preflight_failed": 0,
  "status":           0,
  "warmup":     { "started_at": "...", "ended_at": "..." },
  "ramp":       { "started_at": "...", "ended_at": "..." },
  "saturation": { "started_at": "...", "ended_at": "..." }
}
```

| Field | Meaning |
| --- | --- |
| `trial_id` | Operator's identifier; unique within a campaign |
| `phases` | The phases this trial *should* have run (per the --phases/--skip flags) |
| `phases_run` | The phases that *did* run; for now always equal to `phases` |
| `preflight_failed` | Number of preflight host checks that failed (out of 3 roles) |
| `status` | 0 = all phases returned 0; non-zero = at least one phase returned non-zero |
| Per-phase `started_at`/`ended_at` | Wall-clock for that phase on the load generator host |

## k6-summary files

`k6-summary.json` is the output of k6's `handleSummary` and contains the
full metrics tree. The key slice for the benchmark is the
`http_req_duration{workload:<name>}` histogram; that histogram has the
per-workload p50, p95, p99, p99.9, and max latencies. The benchmark
results table is built by reading those four histograms and the
matching `http_reqs` count, plus the `vus_max` and the framework's own
`http_request_duration_seconds_*` from `/metrics`.

`k6-export.json` is the same content, written by `--summary-export`,
named explicitly per phase so a reader does not have to disambiguate
by timestamp.

`k6-summary.txt` is the human-readable rendering; useful for skimming
without parsing the JSON.

## pg_stat_statements.csv

Top-100 queries by `total_exec_time` (descending) at trial end. The
columns are the standard `pg_stat_statements` view: `query`, `calls`,
`total_exec_time`, `mean_exec_time`, `rows`. A framework that emits 15
queries per `/orders` request will show up here as 15 entries with
similar shapes; a framework that uses one prepared statement will
show up as one entry.

## preflight-*.json

Output of `bench/scripts/preflight.sh --json --role <role>`. Each file
captures:

- `role` -- which node (app, db, loadgen)
- `hostname` -- the host it ran on
- `recorded_at` -- when preflight ran
- `failures` -- number of required checks that failed
- `checks` -- the full list of checks with `name`, `status`
  (pass/fail/observe/warn), `observed`, `expected`, `note`

A measurement run has `failures: 0` on all three roles. Trials with
any failures are recorded but flagged as not publishable by
`bench/scripts/verify-manifest.sh`.

## What lives in /runs inside the loadgen, vs on the host

The loadgen container's `/runs/` named volume holds the raw k6 output
files. `bench/scripts/exec-trial.sh` copies them to
`runs/<trial-id>/<phase>/` on the host as each phase completes. The
named volume is for resilience (if the host filesystem disappears,
the k6 output is still in docker's volume store); the host tree is
for analysis (the run manifest and the analysis tools both read
from `./runs/`).

## Campaign runner

`bench/scripts/run-campaign.sh <framework>` runs a measurement
campaign: `--trials` measured trials plus `--burn-in` discarded
trials (default 4 + 1 = five total, matching the experimental
design). Each trial is a separate `exec-trial.sh` invocation with a
trial-id. After each trial the campaign:

- collects the Prometheus telemetry window via
  `bench/scripts/collect-telemetry.sh`
- retains `docker logs` for each service into `logs/`
- re-runs `verify-manifest.sh` conceptually (the script itself is the
  gate)

```
# five-trial campaign (1 burn-in discarded, 4 measured)
bench/scripts/run-campaign.sh go --trials 4 --burn-in 1
```

## Telemetry series archived

`collect-telemetry.sh` queries Prometheus' range API between the
saturation window's start and end, at a 1s step, for a curated set of
series. The default set (in the script) covers:

- `bench:app:http_request_duration:p99:rate1m` -- the framework's
  server-side p99 from its `/metrics` histogram
- `k6_http_reqs_total` -- client-side throughput, if the loadgen
  pushed via remote-write
- container CPU and RSS for `bench-app` and `bench-db`
- `bench:host:cpu_stealtime_p99:rate5s` and
  `bench:host:psi_cpu_some_p99` -- testbed-isolation signals
- `bench:db:active_connections` and `bench:db:tps:rate1m`

Each series becomes `telemetry/<sanitized-promql>.json` holding the
Prometheus `query_range` response. Series with no data still produce a
file (with an empty `data.result`), so the graph of "what was
observed" is a stable set of files rather than a sparse one.
