# Hono on Bun

Reference implementation of the benchmark contract (`contracts/openapi.yaml`)
on Hono + Bun + postgres.js.

- **Router:** [Hono](https://hono.dev) — a small, fast, standards-based request handler.
- **Database:** [postgres.js](https://github.com/porsager/postgres) (`postgres` npm
  package) — it accepts libpq-style `DATABASE_URL` strings and exposes a
  connection pool with `max`, which is where the contract's `DB_POOL_SIZE` binds.
- **Metrics:** [prom-client](https://github.com/siimon/prom-client) — the
  contracted `http_request_duration_seconds` histogram with `path`/`method`/`status`
  labels, normalized to workload names.

Bun executes TypeScript directly, so `src/index.ts` runs with no build step.

## Building and running

```sh
docker build -t bench/bun:latest -f apps/bun/Dockerfile apps/bun
```

Run it against a database:

```sh
docker run --rm -p 8080:8080 \
  -e DATABASE_URL="postgres://bench:test@host:5432/bench?sslmode=disable" \
  -e DB_POOL_SIZE=32 \
  -e PORT=8080 \
  -e LOG_LEVEL=warn \
  bench/bun:latest
```

Locally (no Docker):

```sh
cd apps/bun
bun install
DATABASE_URL="postgres://bench:test@127.0.0.1:15434/bench?sslmode=disable" \
DB_POOL_SIZE=8 PORT=18082 LOG_LEVEL=error bun run src/index.ts
```

## Environment variables

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | libpq-style connection string (required). Must point at the `bench` database. |
| `DB_POOL_SIZE` | Exact pool size. The `postgres.js` pool `max` is set to this; no second pool is opened. |
| `PORT` | Listen port. Default `8080`. |
| `LOG_LEVEL` | `error` / `warn` / `info` / `debug`. Default `warn`. Nothing is logged per request at `warn`. |

## Concurrency model

Bun uses a single-threaded event loop. `Bun.serve` hands each request to a Hono
handler; the handler is async and the event loop multiplexes every in-flight
request onto the shared database pool.

- **Pools:** one `postgres.js` pool with `max = DB_POOL_SIZE`. Connections are
  opened on demand up to `max` and reused. A transaction (`sql.begin`) borrows
  one connection for its whole lifetime, so an in-flight `POST /orders`
  holds a single slot; the pool bound is respected under contention.
- **Locks:** `POST /orders` dedupes and sorts product ids ascending, then issues
  `SELECT ... FOR UPDATE` per product inside the transaction. This makes the
  stock decrement atomic and avoids deadlocks between concurrent orders that
  touch overlapping product sets in different order.
- **No per-request work off the event loop:** single query endpoints
  (`/products/:id`, `/dashboard`) just await a query; the DB driver does the
  I/O without blocking the loop.

## Observed behavior

Verified against a dedicated Postgres 16 with a small seed
(1000 products, 500 customers, 2000 orders):

```text
9 passed, 0 failed
```

Endpoints exposed: `GET /json`, `GET /products/:id`, `POST /orders`,
`GET /dashboard`, `GET /health`, `GET /metrics`.

## Notes and nuances

- **bigint handling.** The `postgres.js` client returns PostgreSQL `bigint`
  (`int8`) columns as JS *strings* by default (safe beyond `Number.MAX_SAFE_INTEGER`).
  The contract's `id`/`customer_id`/`product_id`/`order_id` and the dashboard's
  `COUNT(...)`/`SUM(...)::bigint` therefore arrive as strings. The handlers parse
  them with `Number(...)` back to integers for the JSON payloads. The `integer`
  columns (`quantity`, `unit_price_cents`, `price_cents`, `stock`, `total_cents`)
  arrive as numbers and are used directly.
- **idempotency_key as `uuid`.** The column is `uuid`, and a bare text parameter
  fails to cast implicitly under PostgreSQL. The handler validates the header is a
  UUID up front (`400` otherwise) and casts explicitly with `::uuid` in both the
  `INSERT ... ON CONFLICT` and the replay `SELECT`. This mirrors the Rust reference.
- **insert/ambiguous:** `ON CONFLICT (idempotency_key) DO NOTHING RETURNING id`
  returns zero rows on a duplicate, which the handler treats as the replay path:
  it rolls back nothing (nothing was written), then reads the original order and
  its `order_items` and returns the same `id` with `201`.
- **`FOR UPDATE` param typing.** Passing JS numbers into `bigint` columns works
  through PostgreSQL's implicit `int4 → int8` promotion; no explicit casts needed
  for `WHERE id = $1`.
- **Metrics cardinality.** `path` is normalized to workload names
  (`json`, `product_read`, `order_write`, `dashboard`, `infra`) via
  `c.req.routePath`, so `/products/1` and `/products/999999999` both land on
  `product_read` and the histogram stays low-cardinality.
- **`/health` is DB-free.** It returns `{"status":"ok"}` without a round trip; the
  pool is only validated at startup (a failed `SELECT 1` exits the process), so a
  running instance with a dropped database still answers `/health`.

## Layout

```
apps/bun/
  src/index.ts   the Hono server (config, pool, middleware, six handlers)
  package.json   hono + postgres + prom-client
  bun.lock      text lockfile for reproducible installs
  Dockerfile     oven/bun multi-stage -> bench/bun:latest
  .dockerignore
  tsconfig.json  editor/types only (no build step)
```
