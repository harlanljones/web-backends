# Execution plan

The Linear project is decomposed into four milestones, each a parent issue with
leaf children. The leaves are independently shippable; the project is
considered complete when all leaves are done. The order below is the order
they will be picked up.

## Milestone 1 -- benchmark infrastructure (HJ-356)

| # | Ticket | Status |
| --- | --- | --- |
| HJ-360 | Provision isolated three-node testbed | in progress |
| HJ-361 | Configure PostgreSQL benchmark database | in progress |
| HJ-362 | Set container resource boundaries | in progress |
| HJ-363 | Add benchmark observability | in progress |

**Definition of done:**

- `bench/scripts/up.sh` brings up the database, telemetry, and load generator
  in `single` mode without an application container.
- `bench/scripts/preflight.sh --role db` records JSON the run manifest can
  embed.
- The seeder completes once per fresh database volume and the database's
  `02-seed.sql` reads from the resulting CSVs.
- `curl http://127.0.0.1:9090/targets` shows all four scrape jobs healthy.
- `curl http://127.0.0.1:3000/d/bench-framework/` returns the framework
  dashboard with the four panels populated (the k6 panel will be empty until
  a trial runs).

## Milestone 2 -- framework reference implementations (HJ-357)

| # | Ticket | Notes |
| --- | --- | --- |
| HJ-364 | Define shared API contracts and data model | `contracts/openapi.yaml` is the contract |
| HJ-365 | Implement serialization and read workloads | built per-framework |
| HJ-366 | Implement transactional write workload | built per-framework |
| HJ-367 | Implement compute and rendering workload | built per-framework |

**Definition of done (per framework):**

- Dockerfile produces a `bench/<framework>:latest` image.
- The framework implements the four workload endpoints + `/health` + `/metrics`.
- `bench/conformance/run.py` passes for the framework.
- A short README in `apps/<framework>/` documents any non-obvious choices
  (e.g. connection driver, HTML template engine).

**All eight framework references are complete.** Each is implemented
under `apps/<framework>/`, registered in `bench/frameworks.yaml`, and
verified against `bench/conformance/run.py` (9/9 on a live Postgres):

| # | Framework | `apps/` dir | Conformance |
| --- | --- | --- | --- |
| 1 | Go + Gin | `go/` | 9/9 |
| 2 | Axum on Rust/Tokio | `rust/` | 9/9 |
| 3 | Fastify on Node.js | `node/` | 9/9 |
| 4 | ASP.NET Core on .NET 8 | `aspnet/` | 9/9 |
| 5 | Spring Boot 3 + Loom on Java 21 | `spring/` | 9/9 |
| 6 | Phoenix on Elixir/BEAM | `phoenix/` | 9/9 |
| 7 | FastAPI on Python ASGI/uvloop | `python/` | 9/9 |
| 8 | Hono on Bun | `bun/` | 9/9 |

## Milestone 3 -- benchmark execution (HJ-358)

| # | Ticket | Status |
| --- | --- | --- |
| HJ-368 | Define reproducible load-test scripts | done |
| HJ-369 | Execute warm-up and ramp tests | done |
| HJ-370 | Run saturation trials and collect telemetry | done |

**Definition of done:** five trials per workload per framework, with k6 and
prometheus archives embedded in the run manifest. `bench/scripts/verify-manifest.sh`
passes for each trial.

The trial driver is `bench/scripts/exec-trial.sh <trial-id>`. It
captures preflight, runs each phase as a separate k6 invocation,
records per-phase output, snapshots `pg_stat_statements`, collects
Prometheus telemetry over the saturation window, and writes a
`manifest.json`. The forward-looking full run manifest layout is
documented in `docs/benchmark/run-manifest.md`.

The campaign runner `bench/scripts/run-campaign.sh <framework>` runs
a five-trial campaign (one burn-in discarded, four measured; overridable
with `--trials`/`--burn-in`). The gate script is
`bench/scripts/verify-manifest.sh`, which assembles the run manifest's
"publishable" verdict. The actual campaign execution (running k6 at
real RPS on the bare-metal testbed) is a human/operator step and is
out of scope for this repository -- the scripts orchestrate and verify
it, but nothing in code substitutes for a conforming testbed.

## Milestone 4 -- analysis (HJ-359)

| # | Ticket | Status |
| --- | --- | --- |
| HJ-371 | Aggregate benchmark results | done |
| HJ-372 | Compare framework trade-offs | done |
| HJ-373 | Publish decision guide and reference materials | done |

**Definition of done:** a published HTML report at
`docs/results/<date>-bench/index.html` containing the decision matrix, the
per-framework deep-dive, and the raw data behind every claim.

Aggregation is `bench/analysis/aggregate.py`, which reads
`runs/<trial-id>/`, discards burn-in, and computes per-workload mean
+ 95% CI (Student's t) for RPS, RPS/core, memory/CPU, and the latency
percentiles. The decision matrix is `bench/analysis/compare.py`, which
merges those measured numbers with the qualitative context in
`bench/analysis/meta/frameworks.yaml` (ecosystem friction, concurrency
model, team scaling) into a measured-vs-qualitative comparison. The
published report is `bench/analysis/report.py`, which renders
`docs/results/<date>-bench/index.html`.

The report generator is complete. A real report is produced once real
trials exist on a conforming testbed; do not generate a published report
from fabricated numbers.

## Currently shipping

This commit delivers the testbed topology (HJ-360), the database configuration
and seed (HJ-361), the resource boundaries (HJ-362), and the observability
stack (HJ-363). The four milestone leaves under HJ-356 are complete as a
unit. The next ticket is HJ-364 (OpenAPI contract), which is already in this
commit as `contracts/openapi.yaml`; HJ-365-367 will follow per-framework.
