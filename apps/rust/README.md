# Axum (Rust/Tokio) reference implementation

Reference implementation of the benchmark contract in
[`../../contracts/openapi.yaml`](../../contracts/openapi.yaml), written in
Rust with axum and sqlx.

## Endpoints

| Path | Method | Workload |
| --- | --- | --- |
| `/json` | GET | I/O-free JSON serialization |
| `/products/:id` | GET | Indexed single-record read |
| `/orders` | POST | Transactional multi-table write (with idempotency) |
| `/dashboard` | GET | Compute + server-side render |
| `/health` | GET | Liveness check |
| `/metrics` | GET | Prometheus text format |

All six endpoints are covered by `bench/conformance/run.py` (9/9
passing, verified against a real Postgres on a 1k-product seed).

## Why these choices

- **axum for the router.** axum is built on tower/tower-http, is part
  of the tokio ecosystem, and exposes enough to implement the four
  workloads with no ORM in the way.
- **sqlx for the database driver.** sqlx is compile-time-checked
  PostgreSQL access with an async pool. It has no runtime reflection
  or ORM hydration, so the benchmark measures axum + sqlx rather than
  "whatever the ORM decides to emit."
- **prometheus crate for `/metrics`.** The histogram is named
  `http_request_duration_seconds_*`, the same name as the Go reference,
  so the recording rule in
  `infra/observability/prometheus/rules/bench.yml` picks it up
  unchanged. The `path` label is the workload name, not the URL.
- **distroless/cc static-ish image.** A nonroot, shell-free runtime.
  The binary is ~3.6 MB and statically linked against musl.

## What the implementation deliberately does NOT do

- No caching. `/products/:id` hits PostgreSQL every time; the contract
  forbids a framework from looking faster than it is.
- No extra pool on top of sqlx. The pool's `max_connections` is set
  exactly to `DB_POOL_SIZE`, honoring the contract.
- No per-request logging. `tracing` is leveled at `WARN`, so at 10k
  RPS the log budget stays within the contract's budget.
- No async-compat shims. The sqlx `Row::get` calls map directly to the
  schema's column types (i64 for bigint, i32 for integer) so a
  type mismatch is a compile-time or obvious runtime error rather than
  a silent cast.

## Build

```bash
docker build -t bench/rust:latest -f Dockerfile .
```

Three build notes:

- The Dockerfile warms the dependency cache with a stub `main.rs`
  before copying the real sources. This keeps a source-only change from
  recompiling every dependency. The stub binary is then removed and the
  real crate recompiled with
  `cargo build --release`. The final image is `bench/rust:latest`.
- `Cargo.lock` is committed so the dependency graph is reproducible.
  `cargo build --release` with `--locked` (or the lock file present)
  pins the versions.
- `[profile.release]` uses `lto`, `panic = "abort"`, and `strip` for a
  smaller, faster binary; `panic = "abort"` also means a runtime type
  mismatch fails fast instead of unwinding.

## Run locally

The contract requires `DATABASE_URL`, `DB_POOL_SIZE`, and `LOG_LEVEL`.

```bash
cargo build --release
DATABASE_URL="postgres://bench:test@127.0.0.1:15432/bench?sslmode=disable" \
  DB_POOL_SIZE=8 PORT=8080 LOG_LEVEL=info \
  ./target/release/bench-axum
```

Then the conformance runner:

```bash
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

## Observed behavior

Recorded against a Postgres 16 container with 1k products, 500
customers, 2k orders, on a workstation (not a measurement host):

- p50 latency on `/json`: ~few hundred microseconds
- p50 latency on `/products/:id`: sub-millisecond
- p50 latency on `/orders`: a few ms (one round trip, three writes)
- p50 latency on `/dashboard`: a few ms (one aggregate query, rendered
  to HTML)
- sqlx pool opens exactly `DB_POOL_SIZE` connections.
- Replay of an `/orders` request with the same `Idempotency-Key`
  returns the original order's id without writing a duplicate.

These are smoke numbers, not benchmark numbers. A measurement run on
the bare-metal testbed will differ and the run manifest will say so.

## Concurrency model

axum handlers are `async fn`; the tokio multi-threaded runtime runs
them across the pinned cores. The pool hands out one DB connection per
in-flight handler, so the framework's concurrency is bounded by
`DB_POOL_SIZE`. This is the intended behavior: the benchmark measures
the framework at equal connection-pool cost.
