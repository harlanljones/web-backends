# Changelog

Notable changes to this repository. The benchmark result (the decision
matrix and its underlying raw data) is published under `docs/results/`
when a conforming testbed campaign has run; see the README for the
distinction between benchmark results and framework-selection guidance.

## [0.5.0] — Full pipeline + 8 framework references

- **Infrastructure (HJ-356)** — three-node testbed topology in
  `docker-compose.yml`, PostgreSQL tuning/schema/seed pipeline, resource
  boundaries, Prometheus/Grafana observability.
- **Framework references (HJ-357)** — eight conformance-clean
  implementations under `apps/` (Go+Gin, Axum, Fastify, ASP.NET,
  Spring Boot 3 + Loom, Phoenix, FastAPI, Hono/Bun). Each is a
  `bench/<framework>:latest` image implementing the shared contract.
- **Benchmark execution (HJ-358)** — k6 protocol (warm-up, ramp,
  saturation), the trial driver `exec-trial.sh`, and the campaign runner
  `run-campaign.sh` with telemetry + system-log retention.
- **Analysis and report (HJ-359)** — `aggregate.py` (mean + 95% CI),
  `compare.py` (measured-vs-qualitative decision matrix), and
  `report.py` (published HTML report).

## [0.1.0] — Initial

- Repository scaffold, benchmark contract
  (`contracts/openapi.yaml`), and the Go + Gin reference
  implementation.

---

## How to read this changelog

- The toolchain and methodology are stable; the reference
  implementations are the code that produces results.
- No testbed numbers are published yet. The scripts and analyzers are
  the deliverable; a result is produced when a conforming bare-metal
  campaign runs (see `docs/benchmark/testbed-hardware.md`).
