# Analysis

Consumes the `runs/<trial-id>/` artifacts produced by
`bench/scripts/exec-trial.sh` / `run-campaign.sh` and turns them into
aggregated, comparable benchmark results.

Two tools:

| Tool | Purpose |
| --- | --- |
| `aggregate.py` | per-framework aggregation with 95% CI |
| `compare.py` | cross-framework decision matrix (measured + qualitative) |
| `report.py` | published HTML report (decision matrix + guide + deep dive) |

## `aggregate.py`

Reads trial directories, discards burn-in, aggregates the measured
trials per workload, and computes the headline metrics with a 95%
confidence interval (Student's t, N-1 dof).

```bash
# auto-discover trial dirs under runs/
python3 bench/analysis/aggregate.py --runs runs

# explicit trial dirs
python3 bench/analysis/aggregate.py --runs runs agg-trial-1 agg-trial-2

# JSON output (input to compare.py and the report generator)
python3 bench/analysis/aggregate.py --runs runs --json > results/go.json
```

### What it does

1. **Discards burn-in** (trial ids matching `burnin` / `burn-in`).
2. **Filters to usable trials** (those with a saturation k6 summary and
   non-zero iterations).
3. **Reads the k6 summary** per workload — latency percentiles from
   `http_req_duration{workload:<name>}`, iteration count from the
   workout's primary status check in `root_group.checks`.
4. **Reads the telemetry** — the app container's mean RSS (`mem_mb`)
   and mean CPU (fraction of one core) from the `telemetry/` series.
5. **Aggregates** each metric: mean, ±95% CI, min, max.
6. **Computes RPS/core** (RPS / app node `cpu_count` from preflight).

### Output

```
trials: 3 total, 1 burn-in discarded, 0 no-data skipped, 2 aggregated
  discarded: agg-trial-0-burnin

=== resources (app container, mean over saturation) ===
metric       n  mean        CI95       min        max
mem_mb       2  120.00      6.00      120.00     132.00
cpu_core     2  1.10        0.06      1.10       1.21

=== json ===
metric       n  mean        CI95       min        max
rps          2  2.00        0.0000     2.00       2.00
rps/core     2  0.0714      0.0000     0.0714     0.0714  (28 cores)
avg_ms       2  0.2919      0.4821     0.2539     0.3298
p95_ms       2  0.3929      1.35       0.2863     0.4994
max_ms       2  0.4091      1.41       0.2980     0.5202
```

`--json` emits the same structure with explicit `mean`/`ci95`/`n`/`min`
/`max` per metric, plus a `results.resources` block. That JSON is what
`compare.py` reads.

## `compare.py`

Merges the measured numbers with the qualitative context
(`bench/analysis/meta/frameworks.yaml`) into a decision matrix.

```bash
# auto-discover results/<framework>.json
python3 bench/analysis/compare.py

# explicit / catalog mode
python3 bench/analysis/compare.py --framework-results results/go.json results/rust.json
python3 bench/analysis/compare.py --catalog catalog.json

# JSON output for the report generator (HJ-373)
python3 bench/analysis/compare.py --json-output report.json
```

### The two dimensions never conflated

- **Measured:** `rps_per_core`, p50/p95/p99/p99.9, `mem_mb`, `cpu`.
  Sourced from `aggregate.py`. This is what the framework did on the
  testbed.
- **Qualitative:** `ecosystem_friction` (1-5), `concurrency_model`,
  `team_scaling`. Sourced from `bench/analysis/meta/frameworks.yaml`.
  This is what it would cost to adopt; it is editorial, not a benchmark
  result.

`compare.py` keeps them in separate columns/sections. It uses the `json`
workload as the cross-workload headline for RPS/core and tail latency
(the serialization floor), and `results.resources` for memory/CPU. The
full per-workload detail is in the `aggregate.py --json` output.

## `report.py`

Renders the published report.

```bash
python3 bench/analysis/compare.py --json-output report.json
python3 bench/analysis/report.py --compare report.json
# -> docs/results/<date>-bench/index.html
```

The report has five parts: header + methodology link, the decision
matrix, a per-framework deep dive, a framework-selection guide (decision
rules by constraint), and a dashboard + reference-codebase + raw-data
appendix. `report.py` takes no measurement input beyond the compare JSON
and the meta yaml; it is purely presentational.

## Relationship to the tickets

- **HJ-371 (aggregate):** `aggregate.py` turns raw trial dirs into one
  table with confidence intervals.
- **HJ-372 (compare trade-offs):** `compare.py` reads the aggregated
  results + the qualitative meta and emits the decision matrix.
- **HJ-373 (publish):** `report.py` consumes `compare.py --json-output`
  and renders `docs/results/<date>-bench/index.html`.

The report's numbers come from `aggregate.py`; its decision matrix comes
from `compare.py`; its prose and the ecosystem-friction editorial are
the human author's (informed by `meta/frameworks.yaml`).

> **Do not commit a report generated from fabricated numbers.** The
> published report is produced from real trial data once a conforming
> testbed campaign has run. `report.py` is the generator; the HTML is
> its output, not its source.
