# ASP.NET Core (.NET 8) reference implementation

A minimal-API ASP.NET Core app on .NET 8 that implements the benchmark
contract in [`contracts/openapi.yaml`](../../contracts/openapi.yaml), matching
the Go and Rust reference implementations. Data access is **Dapper** over
**Npgsql** — no EF Core — so the benchmark measures the framework plus a
raw driver, not an ORM.

Final image: `bench/aspnet:latest`. Entry point: `dotnet /app/publish/Bench.dll`.

## Choices

- **Minimal APIs** (`MapGet`/`MapPost`) rather than controllers. The whole
  surface is 6 endpoints; controllers add MVC machinery that the benchmark
  does not need.
- **Dapper** for SQL. Dapper is a micro-ORM over the raw driver (`NpgsqlConnection`)
  which executes direct SQL; exactly what the benchmark's read and write
  workloads want. `DefaultTypeMap.MatchNamesWithUnderscores = true` maps the
  snake_case columns to PascalCase properties.
- **`NpgsqlDataSource`** as a singleton connection pool, sized with
  `MaxPoolSize = MinPoolSize = DB_POOL_SIZE`. This honors the contract's
  "exactly this many connections" rule: the database sees no second pool on
  top of the configured one.
- **Snake_case wire format.** ASP.NET's default JSON is camelCase, but the
  contract uses `price_cents`, `category_id`, `total_cents`, etc. The app
  configures `JsonNamingPolicy.SnakeCaseLower`, so `Product.Sku` serializes as
  `sku` and the request body's `customer_id` binds back to `CustomerId`.
  (`JsonNamingPolicy.SnakeCaseLower` is .NET 8+; on `SKU`-style all-caps names
  it would produce `s_k_u`, so the model uses `Sku`, `Id`, etc.)
- **Custom Prometheus histogram.** `prometheus-net`'s `UseHttpMetrics()`
  emits `http_request_duration_seconds` labelled `{code,method,controller,action,route}`,
  which is not the contracted shape. Instead a middleware records into its own
  `Histogram` named `http_request_duration_seconds` with labels
  `{path,method,status}`, the `path` being the workload name.
- **Dockerfile** multi-stage from `mcr.microsoft.com/dotnet/sdk:8.0` →
  `mcr.microsoft.com/dotnet/aspnet:8.0`, publishing `-c Release` into
  `/app/publish`, running as the non-root `65534:65534`, listening on
  `http://0.0.0.0:$PORT`.

## Environment variables

| Variable | Handling |
| --- | --- |
| `DATABASE_URL` | libpq-style `postgres://user:pass@host:port/db`. Parsed into an `NpgsqlConnectionStringBuilder` (Npgsql does not accept libpq URLs). |
| `DB_POOL_SIZE` | `MaxPoolSize` **and** `MinPoolSize` on the `NpgsqlDataSource`. Positive integer, default 32. |
| `PORT` | Kestrel binds `http://0.0.0.0:$PORT` via `builder.WebHost.UseUrls`. Default 8080. |
| `LOG_LEVEL` | `error`/`warn`(default)/`info`/`debug`. `SetMinimumLevel` is applied; per-request ASP.NET logs are suppressed at `warn`. |

**`DATABASE_URL` → Npgsql mapping.** The libpq URL is split by hand in
`BuildNpgsqlConnectionString` (scheme, then `userinfo@host:port`, then the
database path, each `Uri.UnescapeDataString`-decoded) and rebuilt with the
Npgsql builder's `Host`/`Port`/`Database`/`Username`/`Password`. The query
string is discarded. A non-`postgres://` value is treated as an already-Npgsql
string and only re-sized.

## Build

```sh
docker build -t bench/aspnet:latest -f apps/aspnet/Dockerfile apps/aspnet
```

The SDK image restores NuGet packages (`Dapper`, `Npgsql`,
`prometheus-net.AspNetCore`) and runs `dotnet publish -c Release -o /app/publish`.
The runtime image copies only the published DLLs and the `Microsoft.AspNetCore.App`
shared framework.

## Observed behavior

Curled against a seeded database (products 1–4 have stock; customer 1 exists):

- `GET /json` → `200 {"service":"bench","version":"1.0.0","time":"<RFC3339 UTC>"}`
- `GET /products/1` → `200` full product (snake_case); `GET /products/999999999` → `404 {"error":"not found"}`
- `POST /orders` → `201` order with `items`; same `Idempotency-Key` again → `201` with the same `id`; missing key → `400`; stock exceeded → `409`
- `GET /dashboard` → `200 text/html` with one `<tr>` per category
- `GET /health` → `200 {"status":"ok"}` (no DB round trip)
- `GET /metrics` → emits `http_request_duration_seconds_bucket{path,method,status}` + `_count`/`_sum`

## Concurrency model

Kestrel dispatches each request to the thread pool; handlers are `async`, so
heavy work (DB) yields threads. There is a single `NpgsqlDataSource` (pool
sized to `DB_POOL_SIZE`) shared across requests; every handler opens a pooled
connection per request. No per-request `DbConnection` is created from scratch.

`POST /orders` opens one connection, begins a transaction, then:

1. `SELECT price_cents, stock ... FOR UPDATE` per product, in **sorted** (deduped)
   product-id order, so overlapping concurrent orders cannot deadlock.
2. Inserts `orders` with `ON CONFLICT (idempotency_key) DO NOTHING RETURNING id`.
3. Inserts `order_items` and `inventory_ledger` (delta = -quantity) and
   decrements `products.stock`.

Two requests for the same product are serialized by the `FOR UPDATE` row lock;
a repeated `Idempotency-Key` hits the unique `idempotency_key` constraint, and
the existing order + items are read back and returned as `201`.

## Notes

- The `aspnet:8.0` base image sets `ASPNETCORE_HTTP_PORTS=8080`; because the app
  binds through `UseUrls` to `$PORT`, the host emits an informational one-time
  "Overriding HTTP_PORTS ... and HTTPS_PORTS ..." warning at startup. It is a
  startup message only — no per-request logging at `LOG_LEVEL=warn`.
- `/health` is intentionally database-free; the process being up is the liveness
  signal, per the contract.
