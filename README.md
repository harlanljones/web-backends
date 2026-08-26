# Modern Web Framework Performance & Scalability Benchmark

**An open, reproducible engineering reference** that compares modern
backend web frameworks under a single, production-like workload.

The point is **not** to crown a winner. It is to make framework
trade-offs visible — throughput, tail latency, resource efficiency,
concurrency behavior, and ecosystem friction — under one contract, on
one testbed, with one dataset. Every number can be re-derived from a
clone of this repo.

## What this measures

Eight framework candidates, four workloads, one contract:

- **Frameworks:** Go+Gin, Axum (Rust/Tokio), Fastify (Node.js),
  ASP.NET Core (.NET 8), Spring Boot 3 + Loom (Java 21), Phoenix
  (Elixir/BEAM), FastAPI (Python ASGI/uvloop), Hono (Bun).
- **Workloads:** I/O-free JSON serialization, indexed single-record
  reads, transactional multi-table writes, and compute-heavy
  server-side-rendered dashboards.
- **Testbed:** an isolated three-node bare-metal cluster (load
  generator, application under test, database) on a private 10 Gbps
  network.
- **Methodology:** three-minute warm-up, ten-minute ramp from 500 to
  10,000 RPS, ten-minute saturation, five trials per candidate with the
  burn-in discarded, and 95% confidence intervals.

Every framework implements the **same HTTP contract**
(`contracts/openapi.yaml`) and reads the **same three environment
variables** (`DATABASE_URL`, `DB_POOL_SIZE`, `LOG_LEVEL`), so the
comparison is a real one.

## What it does *not* measure

Development velocity, ecosystem size, hiring pool, or production
reliability. Those are community properties, not framework properties.
The published report keeps **benchmark results** and **framework
selection guidance** strictly separate.

## Repository layout

```
apps/                      framework reference implementations (8)
  go/         rust/        node/    bun/
  python/     spring/      aspnet/  phoenix/
contracts/                 the OpenAPI 3.1 contract every framework implements
infra/
  postgres/                PostgreSQL tuning, schema, seed pipeline
  observability/           Prometheus, Grafana, recording rules, dashboard
bench/
  seed/                    deterministic CSV data generator
  k6/                      load-generation protocol (warm-up, ramp, saturation)
  conformance/             end-to-end harness that drives a running app
  scripts/                 up/down, preflight, run-trial, exec-trial, campaign
  analysis/                aggregate, compare, report
  frameworks.yaml          registry of registered frameworks
docs/
  agents/                  tracker configuration for AI agents
  benchmark/               methodology, contract, testbed, run-manifest spec
docker-compose.yml         the testbed topology
```

## Quick start (development / smoke)

```bash
# 1. Credentials
cp .env.example .env
$EDITOR .env                 # set POSTGRES_PASSWORD and GRAFANA_ADMIN_PASSWORD

# 2. Bring up the testbed (db, telemetry, loadgen)
./bench/scripts/up.sh

# 3. Build + run a single reference and check the contract against it
./bench/scripts/run-trial.sh go --keep
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

`run-trial.sh <framework>` builds `bench/<framework>:latest`, starts it
against the seeded database, and prints the path to run the conformance
suite. `up.sh` starts the database, telemetry, and load-generator; for a
measurement run you use `run-trial.sh` then `exec-trial.sh`.

> **Important:** single-host (`BENCH_MODE=single`) is for development
> and smoke tests only — the load generator competes with the app for
> CPU. Published results require the distributed bare-metal testbed.

## Running a reproducible trial

```bash
# One five-trial campaign (1 burn-in discarded, 4 measured)
./bench/scripts/run-campaign.sh go --trials 4 --burn-in 1

# The publishability gate
./bench/scripts/verify-manifest.sh runs/<trial-id>

# Aggregated results with 95% confidence intervals
python3 bench/analysis/aggregate.py --runs runs
```

## Interpreting the results

The published artifact distinguishes two kinds of data and never blends
them:

| Kind | What it is | Where it comes from |
| --- | --- | --- |
| **Measured** | what the framework did on the testbed (RPS/core, p50/p95/p99/p99.9, memory, CPU) | the benchmark runs, via `aggregate.py` |
| **Qualitative** | what it would cost to adopt (ecosystem friction, concurrency model, team scaling) | editorial, in `bench/analysis/meta/frameworks.yaml` |

A framework that is fast but has high ecosystem friction is presented as
both facts, not averaged into one number.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: add a
reference under `apps/<framework>/`, register it in
`bench/frameworks.yaml`, and make it pass the conformance suite (9/9).

## Reference material

- **Contract:** [`contracts/openapi.yaml`](contracts/openapi.yaml)
- **Methodology:** [`docs/benchmark/`](docs/benchmark/execution-plan.md)
- **Environment & pinned versions:** [`docs/benchmark/environment.md`](docs/benchmark/environment.md)
- **Run-manifest spec:** [`docs/benchmark/run-manifest.md`](docs/benchmark/run-manifest.md)
- **Tracker config:** [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md)
- **Issue tracker:** [project on Linear](https://linear.app/harlanljones/project/modern-web-framework-performance-and-scalability-benchmark-ab0154b66a94)

## License

[MIT](LICENSE).
