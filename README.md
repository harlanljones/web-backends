# Modern Web Framework Performance & Scalability Benchmark

Open, reproducible benchmark of modern backend web frameworks against a
production-like workload.

The point of this repository is **not** to crown a winner. It is to make
framework trade-offs visible: throughput, tail latency, resource
efficiency, concurrency behavior, and ecosystem friction. Every framework
runs the same contract, on the same testbed, with the same data. The
methodology, the testbed, the load generation, and the data analysis are
all here so a result can be re-derived from a clone of this repo.

The current scope (per the [project on Linear][linear]) is eight framework
candidates evaluated on a four-workload benchmark:

- **Frameworks:** Spring Boot (Loom), ASP.NET Core, Go (Gin/Chi), FastAPI
  (uvloop), Fastify / Next.js, Phoenix (BEAM), Axum (Tokio), Hono / Elysia
  (Bun).
- **Workloads:** I/O-free JSON serialization, indexed single-record reads,
  transactional multi-table writes, compute-heavy server-side rendering.
- **Testbed:** isolated three-node bare-metal cluster (loadgen, app, db)
  on a 10 Gbps private network.
- **Methodology:** three-minute warm-up, ten-minute ramp 500→10,000 RPS,
  ten-minute saturation, five trials per candidate, 95% confidence
  intervals.

[linear]: https://linear.app/harlanljones/project/modern-web-framework-performance-and-scalability-benchmark-ab0154b66a94

## Status

| Milestone | Status |
| --- | --- |
| Benchmark infrastructure (HJ-356) | **complete** |
| Framework reference implementations (HJ-357) | in progress (Go+Gin done; others pending) |
| Benchmark execution (HJ-358) | pending |
| Analysis and report (HJ-359) | pending |

The first commit delivers the testbed topology, the database, the
resource boundaries, the observability stack, and a Go + Gin reference
implementation that passes the conformance suite. The remaining seven
frameworks are independent additions to `apps/`; the testbed does not
change.

## Repository layout

```
apps/                      framework reference implementations
  go/                      Go + Gin (complete, conformance-clean)
contracts/                 shared OpenAPI 3.1 contract every framework implements
infra/
  postgres/                tuning, schema, seed pipeline
  observability/           Prometheus, Grafana, recording rules, dashboard
bench/
  seed/                    deterministic CSV generator
  scripts/                 up.sh, down.sh, preflight.sh, run-trial.sh
  conformance/             end-to-end harness that drives a running app
  frameworks.yaml          registry of registered frameworks
  k6/                      load-generation protocol (warm-up, ramp, saturation)
docs/
  agents/                  tracker configuration for AI agents
  benchmark/               methodology, contract, testbed, run manifest spec
docker-compose.yml         the testbed topology
```

## Quick start

```bash
# 1. Get the credentials into .env
cp .env.example .env
$EDITOR .env       # set POSTGRES_PASSWORD and GRAFANA_ADMIN_PASSWORD

# 2. Bring up the testbed (db, telemetry, loadgen; no app yet)
./bench/scripts/up.sh

# 3. Run a Go + Gin trial
./bench/scripts/run-trial.sh go

# 4. In another terminal, run the conformance suite against the running app
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

The Go + Gin reference implementation builds as `bench/go:latest`. Other
frameworks are added by:

1. Creating `apps/<framework>/` with the implementation, a `Dockerfile`,
   and a `README.md` describing non-obvious choices.
2. Adding an entry to `bench/frameworks.yaml`.
3. Adding `bench/<framework>/` to the conformance runner's expected
   image name (see the runner source for the exact hook).

## What the benchmark measures and does not measure

**It measures** end-to-end request latency (client-side via k6 and
server-side via the framework's `/metrics`), peak RPS, p99 / p99.9 tail
latency, RSS memory and memory per 1,000 active connections, and CPU
utilization. Per-trial five runs, with the burn-in discarded, give
aggregate numbers with 95% confidence intervals.

**It does not measure** development velocity, ecosystem size, hiring
pool, or production reliability. Those are not framework properties; they
are community properties. The published report distinguishes
**benchmark results** from **framework selection guidance** and points
readers at the latter for the things this benchmark cannot speak to.

## Methodology and contract

Every framework implements the same HTTP contract (`contracts/openapi.yaml`)
and reads the same three environment variables (`DATABASE_URL`,
`DB_POOL_SIZE`, `LOG_LEVEL`). The contract is small -- four workload
endpoints plus `/health` and `/metrics` -- so a framework's overhead is
not hidden in a sprawling API surface.

The `docs/benchmark/` directory is the methodology. Start at
`execution-plan.md` for an overview, then `testbed.md` and
`testbed-hardware.md` for the testbed specification, then `app-contract.md`
for what every framework owes, then `database.md`, `resources.md`, and
`observability.md` for the bits the contract does not cover.

## Contributing a new framework

1. Add `apps/<framework>/` with the implementation, `Dockerfile`, and a
   short `README.md`.
2. Add a `bench/<framework>/seed` step if the framework needs framework-
   specific seed data (most do not; the shared seed is the contract).
3. Register the framework in `bench/frameworks.yaml`.
4. Run `./bench/scripts/run-trial.sh <framework>` and confirm the
   conformance suite passes.

The conformance suite is the bar. A framework that does not pass is
not a benchmark candidate, only an example. The whole benchmark is
"frameworks that pass this contract on this testbed"; everything else
is editorial.

## License

To be decided. The implementations are derivative of the contract and
the methodology; the contract and methodology will be released under a
license that permits republication with attribution.
