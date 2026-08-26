# Phoenix (Elixir/BEAM) reference implementation

Reference implementation of the benchmark contract in
[`../../contracts/openapi.yaml`](../../contracts/openapi.yaml), written in
Elixir with Bandit, Plug.Router, and Postgrex.

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

- **Bandit, not Cowboy.** Bandit is a modern, HTTP/2-capable Plug
  server that uses fewer resources per connection than Cowboy. It is
  the BEAM's efficient option for a benchmark whose load is many
  concurrent keep-alive connections.
- **Plug.Router, not the full Phoenix generators.** The benchmark
  measures the framework, not its scaffolding. Phoenix's generators
  add a lot of code (LiveView, channels, contexts) that the four
  workloads never touch. This is a lean Phoenix *runtime* on the
  BEAM, which is the part that matters for throughput and latency.
- **Postgrex directly, no Ecto.** Ecto is an ORM/query layer; its
  association loading and changeset validation are exactly the costs
  the benchmark exists to keep out. Postgrex is the raw async driver
  and its pool is sized to `DB_POOL_SIZE`.
- **Custom minimal Prometheus histogram.** The `telemetry_metrics_prometheus`
  lib targets the `:telemetry` event system, which is a heavy
  dependency for one histogram. A small in-process Agent-backed
  histogram exposes `http_request_duration_seconds_bucket{path,method,status}`
  with the same metric name and labels as the Go/Rust references, so
  the Prometheus recording rule picks it up unchanged.

## What the implementation deliberately does NOT do

- No caching. `/products/:id` hits PostgreSQL every time.
- No second pool on top of Postgrex. The pool is exactly
  `DB_POOL_SIZE`.
- No per-request logging. `LOG_LEVEL = warn` suppresses all request
  logging, so the log budget holds at 10k RPS.
- No Ecto/ORM. Postgrex only.

## Concurrency model

The BEAM runs one Erlang process per request inside the Plug server
(Bandit). Each process has its own heap; the scheduler preempts runs.
This is the actor-model concurrency the project's scope highlights:
many independent lightweight processes with no shared mutable state at
the application layer, with the database pool as the only shared
resource. The framework's concurrency is bounded by `DB_POOL_SIZE`.

## Build

```bash
docker build -t bench/phoenix:latest -f Dockerfile .
```

`Dockerfile` is multi-stage: `elixir:1.16` (OTP 26) compiles the app
and produces an escript, shipped to a small runtime that runs it as a
non-root user. The first build is slow (the BEAM dep tree is large);
subsequent source-only edits rebuild only the app because deps are
cached in a prior layer. `mix.lock` is committed for reproducibility.

## Run locally

The contract requires `DATABASE_URL`, `DB_POOL_SIZE`, and `LOG_LEVEL`.

```bash
DATABASE_URL="postgres://bench:test@127.0.0.1:15438/bench" \
  DB_POOL_SIZE=8 PORT=8080 LOG_LEVEL=info \
  mix run --no-halt
```

Then the conformance runner:

```bash
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

## Observed behavior

Recorded against a Postgres 16 container with 1k products, 500
customers, 2k orders, on a workstation (not a measurement host):

- p50 latency on `/json`: sub-millisecond
- p50 latency on `/products/:id`: sub-millisecond
- p50 latency on `/orders`: a few ms (one transaction, three tables)
- p50 latency on `/dashboard`: a few ms (one aggregate + HTML render)
- Postgrex pool opens exactly `DB_POOL_SIZE` connections.
- Replay of an `/orders` request with the same `Idempotency-Key`
  returns the original order's id without writing a duplicate.

These are smoke numbers, not benchmark numbers.

## Notes

- **uuid handling:** Postgrex expects a `uuid` column value as a 16-byte
  binary, so the `Idempotency-Key` header is converted from its hex
  string form (`...-...-...`) to raw bytes before binding in the
  `INSERT ... ON CONFLICT DO NOTHING` and the replay `SELECT`.
- **Order processing:** products are locked via `SELECT ... FOR UPDATE`
  in sorted id order inside a single Postgrex transaction, and stock is
  decremented in the same transaction, so concurrent identical requests
  cannot over-sell.
