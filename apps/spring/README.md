# Spring Boot 3 + Java 21 (Project Loom) reference implementation

Reference implementation of the benchmark contract in
[`../../contracts/openapi.yaml`](../../contracts/openapi.yaml), written in
Java 21 on Spring Boot 3.4 with virtual threads (Project Loom), plain
`JdbcTemplate` (no ORM), HikariCP, and the Prometheus `simpleclient`.

## Endpoints

| Path | Method | Workload |
| --- | --- | --- |
| `/json` | GET | I/O-free JSON serialization |
| `/products/{id}` | GET | Indexed single-record read |
| `/orders` | POST | Transactional multi-table write (with idempotency) |
| `/dashboard` | GET | Compute + server-side render |
| `/health` | GET | Liveness check |
| `/metrics` | GET | Prometheus text format |

All six endpoints are covered by `bench/conformance/run.py` (verified 9/9
passing against a real Postgres 16 on a 1k-product seed).

## Why these choices

- **Spring Boot 3.4 (`spring-boot-starter-web`).** Tomcat + Spring MVC,
  with `spring.threads.virtual.enabled=true` so the servlet thread pool
  becomes Project Loom virtual threads. Each request is handled on its own
  virtual thread, so the framework's concurrency is bounded by the database
  connection pool (you can't have more in-flight DB calls than connections),
  not by a fixed 200-worker platform-thread pool. This is the whole point of
  measuring Loom here: blocking JDBC calls no longer starve a platform
  thread.
- **`JdbcTemplate` + `spring-boot-starter-jdbc`, no JPA/Hibernate.** No ORM
  means no hydration/reflection/plan-cache cost in the measured path. The
  benchmark measures the framework (Spring Web + Loom + JDBC), not an ORM.
- **HikariCP sized to exactly `DB_POOL_SIZE`.** `maximumPoolSize ==
  minimumIdle == DB_POOL_SIZE`, so the pool opens and holds the contracted
  number of connections, matching the Go (`MinConns == MaxConns`) and Rust
  references. The `bench:db:active_connections` rule therefore sees exactly
  `DB_POOL_SIZE` connections.
- **Prometheus `simpleclient` + hotspot for `/metrics`.** `simpleclient`
  exposes a low-level, allocation-light `Histogram`; `simpleclient_hotspot`
  adds JVM GC/memory collectors. No Micrometer/Spring Actuator, so there is
  only one metrics path and no framework overhead in the histogram.
  The histogram is named `http_request_duration_seconds_*` with labels
  `{path,method,status}`, so the
  `bench:app:http_request_duration:p99:rate1m` recording rule picks it up
  unchanged. `path` is the workload name (`json`, `product_read`,
  `order_write`, `dashboard`, `infra`), normalized from the Spring route
  pattern (`/products/{id}`), not the per-id URI.
- **A `HandlerInterceptor` records the histogram.** Spring MVC's
  `BEST_MATCHING_PATTERN_ATTRIBUTE` gives the route pattern regardless of the
  actual id, so the label stays low-cardinality. `afterCompletion` reads
  `response.getStatus()` and observes elapsed seconds.

## DATABASE_URL -> JDBC mapping

The testbed passes a libpq-style value:

```
DATABASE_URL=postgres://bench:test@127.0.0.1:5432/bench
```

Spring needs `jdbc:postgresql://host:port/db` plus separate username/password.
`DatabaseConfig` parses that `DATABASE_URL` (via `java.net.URI`) and builds
the JDBC URL, extracting `user[:password]` from the userinfo and defaulting
the port to 5432 when absent. Query strings (`?sslmode=disable`) are
ignored; localhost Postgres has no SSL and pgJDBC's default `prefer` falls
back to plaintext. So the same image runs unmodified in the Compose testbed
and the direct `docker run` verification below.

An operator who already has a JDBC URL can bypass the translation entirely by
setting `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, and
`SPRING_DATASOURCE_PASSWORD` (these take precedence).

## Concurrency model

The four workload endpoints run on virtual threads. Blocking JDBC calls from
a virtual thread park the underlying carrier instead of occupying a platform
thread, which is exactly what lets the benchmark push tens of thousands of
requests across a few cores without a fixed-size worker pool becoming the
bottleneck. The real concurrency ceiling is HikariCP's `DB_POOL_SIZE`:
each in-flight handler holds one pooled connection, so the framework cannot
have more concurrent database operations than connections. This is the
intended, contracted behavior — the benchmark measures every framework at
equal connection-pool cost.

`POST /orders` is `@Transactional` (README COMMITTED) on the service method.
It acquires product-row locks via `SELECT ... FOR UPDATE` in sorted product-id
order (deadlock-free for overlapping requests), checks stock, computes the
total, inserts the order, and only then writes items / ledger / decrements
stock. Because each request runs on its own virtual thread, Spring's
per-thread `TransactionSynchronizationManager` state is naturally
isolated — no worker-pool thread is ever reused across two transactions.

## Idempotency

`Idempotency-Key` is a UUID. The `orders.idempotency_key` column is `UNIQUE`;
the insert uses

```sql
INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
VALUES (?, 'pending', ?, ?)
ON CONFLICT (idempotency_key) DO NOTHING RETURNING id
```

with the key passed as `java.util.UUID` via `setObject`. A conflict returns no
row, so the transaction commits as a no-op and the committed original order
(and its items) are read and returned as 201 with the same id and
`status::text`. Note: stock is checked *before* the idempotency insert, so a
replay that would now be out-of-stock returns 409 rather than the original —
this mirrors the Go and Rust references exactly and is what the conformance
runner observes (both frames check stock first).

## LOG_LEVEL / logging

The contract's `LOG_LEVEL` (default `warn`) is mapped onto
`logging.level.root` before the context starts, so at `warn` (the published
level) there is no per-request output and Spring's own INFO startup lines are
suppressed. This keeps the framework inside the benchmark's log-volume
budget. `log_level=error` and `info`/`debug` are also honored.

## PORT

`application.properties` has `server.port=${PORT:8080}`, so the harness's
`PORT` env var selects the port with the contracted default of 8080. Spring's
relaxed name `SERVER_PORT` also overrides it if an operator prefers that.

## Build

```bash
docker build -t bench/spring:latest -f apps/spring/Dockerfile apps/spring
```

Multi-stage: `maven:3.9-eclipse-temurin-21` compiles and repackages the fat
jar (`mvn -q -DskipTests package`), then `eclipse-temurin:21-jre` runs it as a
non-root `bench` user. The build first warms Maven's dependency cache with
`dependency:go-offline` so a source-only edit does not re-download the tree.

## Run + conformance (Docker only)

```bash
docker run -d --name bench-spring-pg -p 15436:5432 \
  -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=test -e POSTGRES_DB=bench \
  -v "$PWD/infra/postgres/postgresql.conf:/etc/postgresql/postgresql.conf:ro" \
  postgres:16 -c config_file=/etc/postgresql/postgresql.conf

docker exec -i bench-spring-pg psql -U bench -d bench < infra/postgres/init/01-schema.sql

# seed small: SEED_PRODUCTS=1000 SEED_CUSTOMERS=500 SEED_ORDERS=2000
# (seed.py writes CSVs; docker cp into the pg container, \copy them, ANALYZE)

mkdir seedout && mkdir -p sx sx/tmp
SEED_PRODUCTS=1000 SEED_CUSTOMERS=500 SEED_ORDERS=2000 python3 bench/seed/seed.py seedout -
# copy the 5 CSVs into the container, psql \copy, then ANALYZE.

docker run -d --network host --name bench-spring-app \
  -e DATABASE_URL="postgres://bench:test@127.0.0.1:15436/bench" \
  -e DB_POOL_SIZE=8 -e PORT=18085 -e LOG_LEVEL=error \
  bench/spring:latest
# poll /health up to 90s (Spring Boot cold start + JIT warm-up can take 10-30s)
python3 bench/conformance/run.py --url http://127.0.0.1:18085 --verbose
```

Spring Boot + Loom + JIT warm-up makes the very first trial slower than the
others; the benchmark's burn-in phase absorbs that. For conformance, poll
`/health` until it returns 200 before running the runner.

## Observed behavior

Smoke numbers against a Postgres 16 container (1k products, 500 customers,
2k orders), not a measurement host:

- `/json`: tens to low hundreds of microseconds (serialization floor, no DB)
- `/products/{id}`: sub-millisecond (one indexed read)
- `/orders`: a few ms (one round trip, three table writes, stock decrement)
- `/dashboard`: a few ms (one aggregate query, server-rendered HTML)
- HikariCP opens exactly `DB_POOL_SIZE` connections; `pg_stat_activity`
  confirms it.
- Repeating `/orders` with the same `Idempotency-Key` returns the original id
  with no duplicate row.

These are smoke numbers, not benchmark numbers; a measurement run on the
bare-metal testbed will differ.
