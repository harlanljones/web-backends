# k6 load-test protocol

Reproducible load generation for the benchmark. Every trial uses the
same protocol so the only thing that varies between framework results
is the framework.

## Scripts

| File | Purpose | When to run |
| --- | --- | --- |
| `warmup.js` | 3 min at 20% of TARGET_RPS, four workloads in parallel | Beginning of every trial |
| `ramp.js` | 10 min ramping from RAMP_START_RPS to TARGET_RPS | After warm-up, before saturation |
| `saturation.js` | 10 min at TARGET_RPS, four workloads in parallel, with thresholds | The measurement |
| `trial.js` | Combined warmup + ramp + saturation in a single k6 run | Convenience for one-shot trials |
| `lib/config.js` | Reads `__ENV` and computes per-phase stages | Used by all four scripts |
| `lib/endpoints.js` | The four workload functions and their scenario definitions | Used by all four scripts |
| `lib/output.js` | Saves the JSON + text summary to `/runs/<timestamp>-summary.{json,txt}` | `handleSummary` for every script |

## How a trial is run end-to-end

The trial driver is `bench/scripts/run-trial.sh`. It:

1. Brings up the database + telemetry + loadgen (if not already up).
2. Waits for the database's `pg_isready` to return healthy.
3. Resets `pg_stat_statements`.
4. Builds and starts the framework's app image.
5. Waits for `/health` to return 200.
6. Resets `pg_stat_statements` again (cold-plan noise is now gone).
7. Prints a reminder to invoke k6 from another terminal.

The k6 invocation is the operator's job, intentionally — it lets the
operator pin RPS, change phase durations, and pipe the run into
`runs/<trial-id>/` without the trial driver getting in the way.

```bash
# in one terminal
./bench/scripts/run-trial.sh go

# in another terminal
docker exec bench-load sh -c '
  k6 run -e TARGET_RPS=10000 /scripts/trial.js
'

# collect the artifacts
./bench/scripts/collect-runs.sh 2026-08-25-go-trial-1
```

For an actual measurement run, replace `trial.js` with three back-to-
back invocations: `warmup.js`, then `ramp.js`, then `saturation.js`,
so the run manifest can record each phase's results separately. The
combined `trial.js` is for development and smoke testing.

## Environment variables

| Variable | Default | Used by |
| --- | --- | --- |
| `TARGET_BASE_URL` | `http://app:8080` | All scripts |
| `TARGET_RPS` | `10000` | All scripts |
| `WARMUP_DURATION` | `3m` | `warmup.js` |
| `WARMUP_RPS_FRAC` | `0.2` | `warmup.js` (20% of TARGET_RPS) |
| `RAMP_DURATION` | `10m` | `ramp.js` |
| `RAMP_START_RPS` | `500` | `ramp.js` |
| `RAMP_END_RPS` | `10000` | `ramp.js` |
| `RAMP_STAGES` | `10` | `ramp.js` |
| `SATURATION_DURATION` | `10m` | `saturation.js` |

For a smoke test, override everything to seconds:

```bash
k6 run \
  -e TARGET_RPS=10 \
  -e WARMUP_DURATION=3s \
  -e RAMP_DURATION=3s \
  -e SATURATION_DURATION=5s \
  -e RAMP_STAGES=2 \
  /scripts/saturation.js
```

## Per-workload VU pools

| Workload | min VUs | max VUs |
| --- | --- | --- |
| `/json` | 50 | 200 |
| `/products/:id` | 50 | 400 |
| `/orders` | 100 | 800 |
| `/dashboard` | 50 | 200 |

These are *starting* values. The number of VUs k6 actually uses at
any moment depends on response latency; k6 will scale up to the max
under load and back down when the rate allows. The values are sized
so a default saturation trial at 10k RPS per workload has 2-3x
headroom in VU count.

## Thresholds

The saturation script enforces:

- `http_req_failed: rate<0.01` (1% error rate, globally and per workload)
- `http_req_duration{workload:<name>}: p(99.9)<1000` (1s p99.9 per workload)

The warm-up and ramp scripts do not enforce thresholds. A framework
that runs out of headroom during warm-up is a finding to record in
the run manifest, not a k6 failure to abort on. The thresholds
become binding at saturation time, where the measurement is.

## Result archival

k6's `handleSummary` writes two files into `/runs/`:

- `<ISO-timestamp>-summary.json` -- the full k6 metrics tree
- `<ISO-timestamp>-summary.txt` -- the human-readable summary

Both files end up on the host at `./runs/<trial-id>/` after
`bench/scripts/collect-runs.sh` is run. The trial-id is the
operator's convention; the timestamp prefix is what the run manifest
records to disambiguate.
