# Application contract

Every framework implements the same four endpoints (see `contracts/openapi.yaml`)
and the same three process-level contracts. The contract is deliberately small;
nothing here is framework-specific and nothing is optional.

## Endpoints

| Path | Workload | Cost profile |
| --- | --- | --- |
| `GET /json` | serialization | no database, no computation |
| `GET /products/{id}` | indexed single-record read | one round trip to the database |
| `POST /orders` | transactional multi-table write | three tables touched, idempotency enforced |
| `GET /dashboard` | compute and rendering | aggregation query, server-side rendered HTML |

Plus a non-workload `GET /health` and `GET /metrics` every framework must
expose. `/health` is the Compose healthcheck target. `/metrics` is the
Prometheus scrape target and must speak the standard text format.

## Environment variables

Every framework must read all three. There are no "framework-native" wrappers;
the experiment deliberately removes the ability to tune pool size or log
level through anything other than the shared variables.

| Variable | Type | Required | Meaning |
| --- | --- | --- | --- |
| `DATABASE_URL` | string | yes | libpq-style connection string |
| `DB_POOL_SIZE` | integer | yes | exact number of connections to open; the framework must not open a second pool on top of this one |
| `PORT` | integer | yes | the framework must listen on this port |
| `LOG_LEVEL` | string | no | one of `error`, `warn`, `info`, `debug`. Default `warn`. |

`LOG_LEVEL=warn` is the published level. A framework that defaults to `info`
will fail the conformance test for log volume at 1 KB/s per 1000 RPS (see
`docs/benchmark/resources.md`).

## Health check

`GET /health` must return 200 within 50 ms when the framework is ready to
serve traffic. The body should be a single line of JSON. The response must
*not* include a database round trip; a framework that depends on the database
for liveness will fail the Compose healthcheck during the warm-up window.

## Metrics

`GET /metrics` is the standard Prometheus text format. The framework is
required to expose at least:

- `http_request_duration_seconds_bucket{path,method,status}` -- a histogram
  of end-to-end request latency, with the path label normalized to the four
  workload names (not including query parameters or path-parameter values)
- `http_request_duration_seconds_count{path,method,status}`
- `http_request_duration_seconds_sum{path,method,status}`

The benchmark's `bench:app:http_request_duration:p99:rate1m` recording rule
in `infra/observability/prometheus/rules/bench.yml` reads these histograms.
Frameworks that do not expose the histogram with this exact name will not
appear in the dashboard.

The framework may also expose additional metrics (connection pool
utilization, GC, event-loop lag, etc.) but they are not contracted and not
required.

## Idempotency

`POST /orders` must accept an `Idempotency-Key` header and use it to dedupe
requests. A retried request with the same key must return the original
order's id without creating a duplicate. This is part of the write workload
because a framework that *does not* implement idempotency will fail
integration with upstream callers; the cost of implementing it correctly
should be part of the published number.
