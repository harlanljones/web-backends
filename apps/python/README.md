# FastAPI (Python ASGI) reference implementation

Reference implementation of the benchmark contract in
[`../../contracts/openapi.yaml`](../../contracts/openapi.yaml), written in
Python with FastAPI, uvicorn (`[standard]`, uvloop), asyncpg, and
prometheus-client.

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
against a real Postgres on a 1k-product seed; see below).

## Why these choices

- **FastAPI for the router + validation.** FastAPI is a thin ASGI layer over
  Starlette. The workload endpoints read the same SQL as the Go and Rust
  references, so the framework comparison measures FastAPI itself, not an
  ORM's plan cache or hydration cost.
- **uvicorn[standard] + uvloop for the server.** `[standard]` pulls UVLoop as
  the event-loop policy and httptools for the HTTP parser. UVLoop is the
  C-accelerated loop that makes the asyncpg sockets the real concurrency
  lever.
- **asyncpg for the database driver.** Direct, non-blocking, protocol-native
  Postgres access. bigint columns come back as Python `int`, `integer` as
  `int`, `boolean` as `bool`, `text` as `str` -- so there is no silent cast
  and nothing to round-trip through an ORM.
- **prometheus-client for `/metrics`.** The histogram is named
  `http_request_duration_seconds_*`, the same name as the Go and Rust
  references, so the recording rule in
  `infra/observability/prometheus/rules/bench.yml` picks it up without
  per-framework changes. The `path` label is the workload name, not the URL.

## Things the implementation deliberately does *not* do

- It does not cache. `/products/:id` hits PostgreSQL every time. A framework
  that caches would look faster and lie about it; the contract forbids it
  implicitly.
- It does not open a second pool. The asyncpg pool's `min_size == max_size ==
  DB_POOL_SIZE`, honouring the "exactly this many" contract. (see *)
- It does not log per request. The uvicorn access log is off, and the app
  itself never logs a request line, so at `LOG_LEVEL=warn` (the published
  level) the log budget stays within the contract.
- It does not add an ORM. asyncpg maps directly to the schema's column types.

## Concurrency model

A single OS process. uvicorn runs uvicorn/uvloop as the event loop with a
default of one worker per process (no `--workers`). Every request is an
`async` coroutine on that one loop. The pool (`asyncpg.Pool`) is the shared
`max_size == DB_POOL_SIZE` set of connections; a coroutine that needs a
connection does `pool.acquire()`, which parks on the loop until a
connection is free. So the request concurrency is bounded by the loop (I/O
bound tasks) and the database conversations are bounded by `DB_POOL_SIZE`.
There is no threading and no process pool.

`/orders` acquires exactly one connection for the whole transaction and runs
`SELECT ... FOR UPDATE` on the ordered, deduped product list. Locking in
sorted id order avoids deadlocks when concurrent requests touch overlapping
product sets; only one such request at a time can decrement a given product's
stock. Idempotency is the `ON CONFLICT (idempotency_key) DO NOTHING`
upsert: a second POST with the same key returns no `RETURNING` row, the
(empty) transaction is rolled back, and the original order is read back and
returned as `201`.

## Build

```bash
docker build -t bench/python:latest -f Dockerfile .
```

(Formally: `docker build -t bench/python:latest -f apps/python/Dockerfile apps/python` from the repo root.)

The build is multi-stage: a `python:3.12-slim` build stage provisions the
dependencies into a venv with uv (copy-linked, byte-compiled), then a second
identical slim stage copies only the venv and `main.py`. The runtime runs as
a non-root `bench` user and listens on 8080.

## Environment variables

| Variable | Type | Default | Meaning |
| --- | --- | --- | --- |
| `DATABASE_URL` | string | (required) | libpq-style connection string |
| `DB_POOL_SIZE` | integer | 32 | exact number of pool connections |
| `PORT` | integer | 8080 | port to listen on |
| `LOG_LEVEL` | string | warn | `error`/`warn`/`info`/`debug` |

## Run locally

The contract requires `DATABASE_URL`, `DB_POOL_SIZE`, and `LOG_LEVEL`. First
provision the venv with uv:

```bash
uv sync
```

Then:

```bash
DATABASE_URL="postgres://bench:test@127.0.0.1:15435/bench?sslmode=disable" \
  DB_POOL_SIZE=8 PORT=18084 LOG_LEVEL=info \
  venv/bin/python main.py
```

Then the conformance runner:

```bash
python3 ../../bench/conformance/run.py --url http://127.0.0.1:18084 --verbose
```

`main.py` also exposes `main:app` so the equivalent single-line form works:

```bash
DATABASE_URL="postgres://bench:test@127.0.0.1:15435/bench?sslmode=disable" \
  DB_POOL_SIZE=8 PORT=18084 LOG_LEVEL=error \
  venv/bin/uvicorn main:app --host 0.0.0.0 --port 18084 --no-access-log
```

The launcher (`python main.py`) is what the container `ENTRYPOINT` uses,
because an exec-form entrypoint array cannot expand `$PORT` from the
environment; it reads `PORT` and `LOG_LEVEL` itself and calls `uvicorn.run`
with the access log off.

## Observed behavior

Recorded against a Postgres 16 container with 1k products, 500 customers,
2k orders, on a workstation (not a measurement host):

- conformance: 9 passed, 0 failed.
- bigint columns (`id`, `order_count`, `total_cents`) deserialize to Python
  `int`; `price_cents`/`stock`/`category_id` are `integer` and also `int`;
  `active` is a real `bool`.
- the asyncpg pool opens exactly `DB_POOL_SIZE` connections (`min_size ==
  max_size`).
- replay of an `/orders` request with the same `Idempotency-Key` returns the
  original order id without writing a duplicate.
- `/products/{id}` returns `404` for an unknown id, `200` for a known one.
- `/metrics` exposes `http_request_duration_seconds_bucket` with
  `method`, `status`, and `path` (workload-name) labels.

These are smoke numbers, not benchmark numbers. A measurement run on the
bare-metal testbed will be different and the run manifest will say so.

## Nuances

- **uvicorn lifespan:** the pool is created in FastAPI's `lifespan` startup
  and closed on shutdown. `/health` does not touch the database, so the
  Compose healthcheck fires even if the pool is still warming.
- **Pool sizing:** `DB_POOL_SIZE` maps to both `min_size` and `max_size`, so
  the pool opens exactly that many connections and never idles below it. This
  mirrors the Go reference's `MinConns == MaxConns`.
- **bigint/uuid handling:** asyncpg returns `int8`/`int4` as Python `int` and
  `bool` as `bool`, so there is no cast needed. The `idempotency_key` column
  is Postgres `uuid`; the header string is parsed with `uuid.UUID` and bound
  as a `uuid.UUID` object, which asyncpg encodes natively (no `::uuid` cast
  required). An unparseable header is a `400`.
- **Idempotency:** `ON CONFLICT (idempotency_key) DO NOTHING RETURNING id`.
  A no-row `RETURNING` is the replay signal; the transaction is rolled back
  and the original order is read and re-serialized as `201`.
- **uvloop:** `uvicorn[standard]` installs uvloop and installs it as the
  event-loop policy automatically, so `uvicorn.run` uses the C loop without
  extra config.
