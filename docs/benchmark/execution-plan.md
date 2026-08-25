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
- `bench/conformance/run.sh` passes for the framework.
- A short README in `apps/<framework>/` documents any non-obvious choices
  (e.g. connection driver, HTML template engine).

**Framework priority order** (driven by which runtimes are available on the
testbed's bare-metal OS):

1. Go with Gin (or Chi)
2. Axum on Rust/Tokio
3. Fastify on Node.js
4. ASP.NET Core on .NET 8
5. Spring Boot 3 on Java 21 with Loom
6. Phoenix on Elixir/BEAM
7. FastAPI on Python ASGI/uvloop
8. Hono or Elysia on Bun

The order is also a likely "ship it first" order -- the runtime of choice is
the one most likely to be installed on the operator's workstation, so a
reference implementation lets us validate the harness early.

## Milestone 3 -- benchmark execution (HJ-358)

| # | Ticket | Status |
| --- | --- | --- |
| HJ-368 | Define reproducible load-test scripts | pending |
| HJ-369 | Execute warm-up and ramp tests | pending |
| HJ-370 | Run saturation trials and collect telemetry | pending |

**Definition of done:** five trials per workload per framework, with k6 and
prometheus archives embedded in the run manifest. `bench/scripts/verify-manifest.sh`
passes for each trial.

## Milestone 4 -- analysis (HJ-359)

| # | Ticket | Status |
| --- | --- | --- |
| HJ-371 | Aggregate benchmark results | pending |
| HJ-372 | Compare framework trade-offs | pending |
| HJ-373 | Publish decision guide and reference materials | pending |

**Definition of done:** a published HTML report at
`docs/results/<date>-bench/index.html` containing the decision matrix, the
per-framework deep-dive, and the raw data behind every claim.

## Currently shipping

This commit delivers the testbed topology (HJ-360), the database configuration
and seed (HJ-361), the resource boundaries (HJ-362), and the observability
stack (HJ-363). The four milestone leaves under HJ-356 are complete as a
unit. The next ticket is HJ-364 (OpenAPI contract), which is already in this
commit as `contracts/openapi.yaml`; HJ-365-367 will follow per-framework.
