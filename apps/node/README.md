# Fastify (Node.js) reference implementation

A Node.js implementation of the benchmark contract in
[`contracts/openapi.yaml`](../../contracts/openapi.yaml), on **Fastify** +
[`pg`](https://node-postgres.com) (node-postgres) + [`prom-client`](https://github.com/siimon/prom-client).

It implements the same four workloads, `/health`, and `/metrics` as the
[Go+Gin](../../apps/go) and [Rust+Axum](../../apps/rust) references, against
the same PostgreSQL schema.

## Choices

- **Fastify** for the HTTP layer. Its router gives fast parameterized routes
  (`/products/:id`), a built-in JSON body parser for `/orders`, and a pino
  logger whose level is controllable via `LOG_LEVEL`.
- **`pg` (node-postgres)** for the database. We use one shared `pg.Pool`
  sized to `DB_POOL_SIZE`. `/orders` takes an explicit client out of the pool
  to run its multi-statement transaction; every other handler uses the pool.
- **`prom-client`** with a custom registry that holds a single `Histogram`,
  `http_request_duration_seconds`, labeled `{path, method, status}`. The
  `path` label is the *workload name* (`json`, `product_read`, `order_write`,
  `dashboard`, `infra`), not the URL, keeping it low-cardinality.
- **No caching.** `/products/:id` hits PostgreSQL every request, matching the
  references. A framework that caches would look faster and distort the read
  workload.

## bigint handling

The schema uses `bigint` for `id`, `customer_id`, `product_id`, `order_id`,
`order_id` in `order_items`, and the `::bigint` casts the dashboard uses.
node-postgres returns `bigint` as a **string** by default and `integer` as a
JS number. The contract wants JS numbers for the JSON responses, so we
register an `int8` (OID 20) type parser in `src/index.js`:

```js
types.setTypeParser(20, (v) => Number(v));
```

Benchmark ids are far below `Number.MAX_SAFE_INTEGER`, so the round-trip is
lossless. `status::text`, `price_cents`, `quantity`, and `total_cents` are
`integer` and already come back as numbers.

## Pool sizing and concurrency

`DB_POOL_SIZE` sets the pool `max` exactly. node-postgres has no minimum
pool size, so at startup we `pool.connect()` `DB_POOL_SIZE` times and run
`SELECT 1` to warm the pool up to its ceiling. The pool can therefore never
hold more than `DB_POOL_SIZE` connections, which is what the
`active_connections` recording rule checks. This is the same contract the
Go reference enforces with `MinConns = MaxConns = DB_POOL_SIZE`.

The concurrency model is the standard Fastify event loop plus the physical
pool: each request is handled on the event loop, and the database work is
delegated to the Postgres clients. `/orders` uses `SELECT ... FOR UPDATE`
inside a single transaction over the product rows **locked in sorted id
order** to avoid deadlocks between concurrent overlapping requests.

## Idempotency

`/orders` requires the `Idempotency-Key` header (it is a `uuid` column).
On insert we use:

```sql
INSERT INTO orders (...) VALUES (...)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING id
```

- A non-empty `RETURNING id` means the order was created; we then write
  `order_items`, `inventory_ledger`, and decrement `products.stock`, and
  commit.
- An empty result means the key already exists; we roll back the (read-only)
  transaction, read the committed order and its items by key, and return **201
  with the original id** — never a duplicate row.

## Environment

| Variable      | Default | Purpose                                      |
| ------------- | ------- | -------------------------------------------- |
| `DATABASE_URL`| —       | Postgres connection string (required)        |
| `DB_POOL_SIZE`| `32`    | Exact pool size / max connections            |
| `PORT`        | `8080`  | Listen port                                  |
| `LOG_LEVEL`   | `warn`  | pino level. At `warn`/`error` no per-request logs |

At `LOG_LEVEL=warn` (the contract default) Fastify's info-level per-request
logs are dropped, so the log-volume budget is not blown on a busy workload.

## Build

```sh
docker build -t bench/node:latest -f apps/node/Dockerfile apps/node
```

Multi-stage: a `deps` stage running `npm ci --omit=dev` (prod deps only, from
the committed lockfile) feeds a slim runtime image that runs as the non-root
`node` user. No dev dependencies are shipped.

Run with env vars supplied at runtime:

```sh
docker run --rm -p 8080:8080 \
  -e DATABASE_URL="postgres://bench:test@127.0.0.1:15433/bench?sslmode=disable" \
  -e DB_POOL_SIZE=8 -e PORT=8080 -e LOG_LEVEL=warn \
  bench/node:latest
```

## Observed behavior

Verified against a seeded Postgres (1000 products / 500 customers / 2000
orders). All 9 conformance checks pass:

- `GET /health` → `200 {"status":"ok"}` (no DB round trip)
- `GET /json` → the static `{service,version,time}` shape
- `GET /products/1` → 200 with the row; `GET /products/999999999` → 404
- `GET /metrics` → Prometheus text containing the
  `http_request_duration_seconds_bucket{path,method,status}` histogram
- `GET /dashboard` → `text/html` with a `<table>`
- `POST /orders` → 201; missing `Idempotency-Key` → 400; replay returns the
  same id

## Files

- `src/index.js` — Fastify app, routes, hooks, metrics, pool
- `package.json`, `package-lock.json` — pinned deps + reproducible lockfile
- `Dockerfile` — multi-stage image
- `.dockerignore`
