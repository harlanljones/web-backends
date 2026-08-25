# Go + Gin reference implementation

Reference implementation of the benchmark contract in
[`../../contracts/openapi.yaml`](../../contracts/openapi.yaml), written in
Go with Gin and `pgx/v5`.

## Endpoints

| Path | Method | Workload |
| --- | --- | --- |
| `/json` | GET | I/O-free JSON serialization |
| `/products/:id` | GET | Indexed single-record read |
| `/orders` | POST | Transactional multi-table write (with idempotency) |
| `/dashboard` | GET | Compute + server-side render |
| `/health` | GET | Liveness check |
| `/metrics` | GET | Prometheus text format |

All six endpoints are covered by `bench/conformance/run.py` (9/9 passing
on the registered test database).

## Why these choices

- **Gin for the router.** It is a thin, fast router and its per-request
  overhead is in the noise for the four workloads. A "more featured"
  framework (echo, fiber, chi) would also pass the contract; the testbed
  is meant to compare across language families, not across Go routers.
- **pgx/v5 for the database driver.** pgx is the most direct path to
  PostgreSQL in Go and exposes prepared-statement caching, `COPY`, and
  `pgx.ErrNoRows` without an ORM in the way. An ORM (GORM, ent) would
  add plan-cache, hydration, and reflection costs that the benchmark
  exists to measure; an ORM is exactly the kind of thing the framework
  comparison should surface, so the Go reference deliberately uses
  neither.
- **Distroless static image.** The final image is ~10 MB, has no shell,
  and runs as `nonroot`. A smaller, less surprising runtime is a
  smaller variable in the benchmark.
- **HTML rendered with `fmt.Fprintf` to a `[]byte`.** The dashboard is
  not the place to spend a template engine's complexity. `html.EscapeString`
  covers the XSS-relevant escape, and the output is the contract: HTML
  with a `<table>`.

## Things the implementation does deliberately *not* do

- It does not cache. A framework that caches `/products/:id` would look
  faster than the others and lie about it; the contract forbids it
  implicitly because the benchmark records per-request.
- It does not add a goroutine pool on top of `pgxpool`. pgx is already
  non-blocking under the hood; an extra pool would just steal CPU from
  the work.
- It does not log per request. With the default `gin.New()`, the per-
  request log line is silent. At 10,000 RPS, that is one less line per
  request, which is the difference between "fits in the 1 KB/s per 1000
  RPS budget" and "floods the container's log driver".
- It does not expose a separate /admin or /debug endpoint. The contract
  is six endpoints; adding more would dilute the benchmark's view of
  "what does this framework cost for these four workloads?".

## Build

```bash
docker build -t bench/go:latest -f Dockerfile .
```

The build is a standard multi-stage Go build. CGO is disabled; the
resulting binary is statically linked, so the distroless runtime image
needs no glibc or package manager.

## Run locally

The contract requires `DATABASE_URL`, `DB_POOL_SIZE`, and `LOG_LEVEL`.

```bash
DATABASE_URL="postgres://bench:test@127.0.0.1:15432/bench?sslmode=disable" \
  DB_POOL_SIZE=8 PORT=18080 LOG_LEVEL=info \
  ./bench-go
```

Then the conformance runner:

```bash
python3 bench/conformance/run.py --url http://127.0.0.1:18080 --verbose
```

## Observed behavior

Recorded against a Postgres 16 container with 1k products, 500 customers,
2k orders, on a workstation (not a measurement host):

- p50 latency on `/json`: ~150 microseconds
- p50 latency on `/products/:id`: ~600 microseconds
- p50 latency on `/orders`: ~3 ms (one round trip, three writes)
- p50 latency on `/dashboard`: ~3 ms (one aggregate query, server-side
  rendered to ~3 KB of HTML)
- pgxpool opens exactly `DB_POOL_SIZE` connections; `pg_stat_activity`
  confirms the count.
- Replay of an `/orders` request with the same `Idempotency-Key` returns
  the original order's id without writing a duplicate.

These are smoke numbers, not benchmark numbers. A measurement run on
the bare-metal testbed will be different and the run manifest will say
so.
