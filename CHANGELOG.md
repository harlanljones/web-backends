# Changelog

Notable changes to this repository. The benchmark result (the decision
matrix and its underlying raw data) is published under `docs/results/`
when a conforming testbed campaign has run; see the README for the
distinction between benchmark results and framework-selection guidance.

## [1.0.0] — Launch: reproducible read benchmark + correctness fixes

The 1.0 release is the launch of the toolchain and methodology. It adds the
first real (single-host) read benchmark as a labeled pipeline demonstration,
fixes a set of correctness bugs that would have silently invalidated any
measurement, and raises the repository to v1.0 community standards
(conformance in CI, community files, hardened static analysis).

### New: read benchmark + report

- **`WORKLOADS` filter** — the k6 phase scripts now accept a comma-separated
  `WORKLOADS` env var, so a run can be scoped to a read-only subset
  (`json,product_read`) without mutating the seed.
- **First read benchmark** — all eight references were built, conformance
  verified 9/9, and a fixed-load read trial was run for each on a single
  host. The labeled result lives at
  `docs/results/2026-08-26-bench/index.html` and carries a prominent
  "single-host development result" notice (it is *not* a bare-metal
  publishable number).
- **Report notice** — `report.py --notice` renders a caveat banner so a
  pipeline demonstration can never be mistaken for a measurement.

### Correctness fixes

These would have silently corrupted a measurement; they are the most
important part of the release.

- **k6 saturation halving (critical)** — `ramping-arrival-rate` ramps from
  `startRate` (default 0), so a single-stage saturation averaged *half* the
  intended RPS. The phases now pin `startRate` per phase, so saturation
  genuinely sustains `TARGET_RPS`. (`bench/k6/lib/config.js`,
  `lib/endpoints.js`, phase scripts.)
- **k6 percentiles** — `summaryTrendStats` now computes `p(99)`/`p(99.9)`,
  which `aggregate.py` and the methodology require but the default k6
  summary omitted.
- **`aggregate.py`** — fixed a crash when a workload had no latency data
  (`pt.get("latency") or {}`), and RPS/core now uses the app's allocated
  cores (`config.app_cores`) instead of the host's `nproc`.
- **Telemetry** — `exec-trial.sh` now reads the saturation window from the
  phase `.started_at`/`.ended_at` files (the manifest's `saturation` block
  is written *after* the telemetry step) and the phase-comma condition no
  longer silently skipped telemetry. `aggregate.py` correctly separates the
  app's `container_memory_rss` from the cAdvisor CPU rate instead of
  averaging them into one number.
- **Framework image detection** — a standalone `exec-trial.sh` no longer
  records `framework_image: unknown`; it reads the running `bench-app`
  container's image.
- **Container networking** — the trial driver targets the app's service
  name (`app`) rather than `127.0.0.1`, which is the loadgen's own loopback
  and was refused.
- **`APP_IMAGE` interpolation** — `down.sh` and `run-trial.sh` now export a
  placeholder so a teardown/platform stage works when no framework is named
  (matching `up.sh`).
- **Python reference** — `LOG_LEVEL=warn` is translated to uvicorn's
  `warning`; the app now starts under the shared contract value.
- **`.env.example` / orchestration** — `BENCH_*_IP` renamed to
  `BENCH_*_HOST`; the values are commented out by default because
  setting them breaks `single` mode (the compose file falls back to
  container DNS names). `docs/benchmark/testbed.md` no longer refers to a
  non-existent `justfile`.
- **Shellcheck** — scripts pass `shellcheck -S warning` (glob for the NIC
  loop, unused-variable cleanup).

### CI and community

- **CI** — three jobs: `lint` (shellcheck + ruff + config), `frameworks`
  (registry consistency), `pipeline` (analysis pipeline against the
  synthetic fixture), and `conformance` (build the Go reference against a
  Postgres service and assert 9/9).
- **Community files** — `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue
  templates (bug report + new-framework proposal), PR template.
- **Docs** — `docs/README.md`, `docs/benchmark/README.md`,
  `docs/results/README.md` (the no-fabrication rule), and per-tool READMEs
  for `bench/seed/` and `bench/conformance/`.
- **README** — badges (CI, MIT, conformance), a `WORKLOADS` example, and a
  Results section that distinguishes bare-metal from development runs.

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
- The only published result to date is a labeled single-host development
  read benchmark (`docs/results/2026-08-26-bench/`). A bare-metal result is
  produced when a conforming campaign runs on the three-node testbed (see
  `docs/benchmark/testbed-hardware.md`); until then, no number on this page
  is a measurable publication.
