"""FastAPI (Python ASGI, uvicorn, uvloop) reference implementation of the
benchmark contract.

Implements the six contract endpoints against contracts/openapi.yaml using
FastAPI + uvicorn[standard] (uvloop) + asyncpg + prometheus-client.

The three contract environment variables are read at startup and held
constant:

  DATABASE_URL  libpq-style connection string (required)
  DB_POOL_SIZE  exact number of connections in the pool (required, > 0)
  PORT          port to listen on (default 8080)
  LOG_LEVEL     error | warn | info | debug (default warn). At warn there is
                NO per-request logging: the uvicorn access log is off.

This module exposes two entry points:

  * `main:app` -- the FastAPI application, importable by uvicorn
  * `python main.py` -- a launcher that reads PORT/LOG_LEVEL from the
    environment and runs the app. This is what the container entrypoint
    uses so it honours the PORT and LOG_LEVEL contract without needing a
    shell to expand environment variables in an exec-form entrypoint.

Deliberately not done:

  * No caching. /products/{id} hits PostgreSQL every time; the contract
    forbids a framework from looking faster than it is.
  * No second pool on top of asyncpg. The pool's min_size == max_size ==
    DB_POOL_SIZE, honouring the contract.
  * No per-request logging. The uvicorn access log is disabled, so at
    LOG_LEVEL=warn (the published level) the log budget stays within the
    contract.
"""

from __future__ import annotations

import html
import os
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

import asyncpg
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from prometheus_client import CollectorRegistry, CONTENT_TYPE_LATEST, Histogram, generate_latest

LOG_LEVEL = os.environ.get("LOG_LEVEL", "warn").lower()

# ---------------------------------------------------------------------------
# Database pool.
#
# Built to the contract: exactly DB_POOL_SIZE connections, no more, no fewer.
# min_size == max_size so the pool does not idle below its configured size
# during the warm-up phase and never opens a second pool on top of this one.
# ---------------------------------------------------------------------------

pool: asyncpg.Pool | None = None


async def create_pool() -> asyncpg.Pool:
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError("DATABASE_URL must be set")
    size = int(os.environ.get("DB_POOL_SIZE", "32"))
    if size <= 0:
        raise RuntimeError("DB_POOL_SIZE must be > 0")
    return await asyncpg.create_pool(
        dsn=dsn,
        min_size=size,
        max_size=size,
        command_timeout=30,
        max_inactive_connection_lifetime=300,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await create_pool()
    try:
        yield
    finally:
        await pool.close()
        pool = None


def get_pool() -> asyncpg.Pool:
    if pool is None:
        raise RuntimeError("database pool is not initialized")
    return pool


# ---------------------------------------------------------------------------
# Prometheus metrics.
#
# The histogram is named http_request_duration_seconds_* so the recording
# rule in infra/observability/prometheus/rules/bench.yml picks it up without
# per-framework changes. The `path` label is the workload name, not the URL
# pattern, so it stays low-cardinality. A dedicated registry keeps /metrics
# focused on what the contract requires.
# ---------------------------------------------------------------------------

REGISTRY = CollectorRegistry()
REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "End-to-end request latency, in seconds.",
    ["path", "method", "status"],
    registry=REGISTRY,
)


def normalize_path(path: str) -> str:
    """Map a request path to its workload name.

    /products/{id} is normalized to "product_read" so a per-id label set
    never explodes Prometheus. The four workload names are json,
    product_read, order_write, dashboard; /health and /metrics are "infra".
    """
    if path.startswith("/products/"):
        return "product_read"
    return {
        "/json": "json",
        "/orders": "order_write",
        "/dashboard": "dashboard",
        "/health": "infra",
        "/metrics": "infra",
    }.get(path, "other")


# ---------------------------------------------------------------------------
# SQL (identical to the Go and Rust references, byte for byte).
# ---------------------------------------------------------------------------

PRODUCT_SELECT = """
SELECT id, sku, name, description, category_id, price_cents, stock, active
FROM products
WHERE id = $1
"""

LOCK_PRODUCT = "SELECT price_cents, stock FROM products WHERE id = $1 FOR UPDATE"

INSERT_ORDER = """
INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
VALUES ($1, 'pending', $2, $3)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING id
"""

SELECT_ORDER_BY_KEY = """
SELECT id, customer_id, status::text, total_cents
FROM orders
WHERE idempotency_key = $1
"""

SELECT_ORDER_ITEMS = """
SELECT product_id, quantity, unit_price_cents
FROM order_items
WHERE order_id = $1
"""

INSERT_ITEM = """
INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents)
VALUES ($1, $2, $3, $4)
"""

INSERT_LEDGER = """
INSERT INTO inventory_ledger (product_id, order_id, delta)
VALUES ($1, $2, $3)
"""

UPDATE_STOCK = """
UPDATE products SET stock = stock - $1, updated_at = now() WHERE id = $2
"""

DASHBOARD_AGG = """
SELECT
  c.id,
  c.name,
  COUNT(o.id)         AS order_count,
  COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents
FROM categories c
LEFT JOIN orders o
  ON o.status IN ('paid', 'shipped')
  AND o.created_at >= now() - ($1::int || ' days')::interval
  AND EXISTS (
    SELECT 1 FROM order_items oi
    JOIN products p ON p.id = oi.product_id
    WHERE oi.order_id = o.id AND p.category_id = c.id
  )
GROUP BY c.id, c.name
ORDER BY c.id
"""


def rfc3339_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------------------
# Application.
# ---------------------------------------------------------------------------

app = FastAPI(title="bench", version="1.0.0", lifespan=lifespan)


@app.middleware("http")
async def track_latency(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start
    path = normalize_path(request.url.path)
    REQUEST_DURATION.labels(path, request.method, str(response.status_code)).observe(elapsed)
    return response


# ---------------------------------------------------------------------------
# 1. /json -- I/O-free JSON serialization floor.
# ---------------------------------------------------------------------------

@app.get("/json")
async def get_json():
    return JSONResponse(
        {"service": "bench", "version": "1.0.0", "time": rfc3339_now()},
        status_code=200,
    )


# ---------------------------------------------------------------------------
# 2. /products/{id} -- indexed single-record read.
# ---------------------------------------------------------------------------

@app.get("/products/{product_id}")
async def get_product(product_id: int):
    row = await get_pool().fetchrow(PRODUCT_SELECT, product_id)
    if row is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse(dict(row), status_code=200)


# ---------------------------------------------------------------------------
# 3. /orders -- transactional multi-table write with idempotency.
# ---------------------------------------------------------------------------

def parse_body(body: Any) -> tuple[int | None, list[dict] | None]:
    if not isinstance(body, dict):
        return None, None
    customer_id = body.get("customer_id")
    items = body.get("items")
    if not isinstance(customer_id, int) or customer_id <= 0:
        return None, None
    if not isinstance(items, list) or not items or len(items) > 20:
        return None, None
    for it in items:
        if not isinstance(it, dict):
            return None, None
        pid = it.get("product_id")
        qty = it.get("quantity")
        if not isinstance(pid, int) or pid <= 0:
            return None, None
        if not isinstance(qty, int) or qty <= 0 or qty > 1000:
            return None, None
    return customer_id, items


@app.post("/orders")
async def create_order(request: Request):
    idem_key = request.headers.get("Idempotency-Key")
    if not idem_key:
        return JSONResponse({"error": "Idempotency-Key header is required"}, status_code=400)
    try:
        idem_uuid = uuid.UUID(idem_key)
    except ValueError:
        return JSONResponse({"error": "invalid Idempotency-Key"}, status_code=400)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "invalid body"}, status_code=400)

    customer_id, items = parse_body(body)
    if customer_id is None or items is None:
        return JSONResponse({"error": "invalid body"}, status_code=400)

    p = get_pool()
    async with p.acquire() as conn:
        tx = conn.transaction()
        await tx.start()
        try:
            # Lock product rows in id order, deduped, to avoid deadlocks
            # when concurrent requests touch overlapping product sets.
            product_ids = sorted({it["product_id"] for it in items})
            prices: dict[int, dict[str, int]] = {}
            for pid in product_ids:
                row = await conn.fetchrow(LOCK_PRODUCT, pid)
                if row is None:
                    await tx.rollback()
                    return JSONResponse({"error": "unknown product", "product_id": pid}, status_code=400)
                prices[pid] = {"price": row["price_cents"], "stock": row["stock"]}

            total = 0
            for it in items:
                pid = it["product_id"]
                qty = it["quantity"]
                if prices[pid]["stock"] < qty:
                    await tx.rollback()
                    return JSONResponse(
                        {
                            "error": "insufficient stock",
                            "product_id": pid,
                            "available": prices[pid]["stock"],
                            "requested": qty,
                        },
                        status_code=409,
                    )
                total += prices[pid]["price"] * qty

            row = await conn.fetchrow(INSERT_ORDER, customer_id, total, idem_uuid)
            if row is None:
                # Replay: a row with this idempotency_key already exists.
                await tx.rollback()
                return await replay_order(p, idem_uuid)

            order_id = row["id"]
            for it in items:
                pid = it["product_id"]
                qty = it["quantity"]
                price = prices[pid]["price"]
                await conn.execute(INSERT_ITEM, order_id, pid, qty, price)
                await conn.execute(INSERT_LEDGER, pid, order_id, -qty)
                await conn.execute(UPDATE_STOCK, qty, pid)

            await tx.commit()

            items_resp = [
                {
                    "product_id": it["product_id"],
                    "quantity": it["quantity"],
                    "unit_price_cents": prices[it["product_id"]]["price"],
                }
                for it in items
            ]
            return JSONResponse(
                {
                    "id": order_id,
                    "customer_id": customer_id,
                    "status": "pending",
                    "total_cents": total,
                    "items": items_resp,
                },
                status_code=201,
            )
        except Exception:
            await tx.rollback()
            raise


async def replay_order(p: asyncpg.Pool, idem_uuid: uuid.UUID):
    row = await p.fetchrow(SELECT_ORDER_BY_KEY, idem_uuid)
    if row is None:
        return JSONResponse({"error": "internal error"}, status_code=500)
    order_id = row["id"]
    items_rows = await p.fetch(SELECT_ORDER_ITEMS, order_id)
    items = [
        {
            "product_id": r["product_id"],
            "quantity": r["quantity"],
            "unit_price_cents": r["unit_price_cents"],
        }
        for r in items_rows
    ]
    return JSONResponse(
        {
            "id": order_id,
            "customer_id": row["customer_id"],
            "status": row["status"],
            "total_cents": row["total_cents"],
            "items": items,
        },
        status_code=201,
    )


# ---------------------------------------------------------------------------
# 4. /dashboard -- compute + server-side render.
# ---------------------------------------------------------------------------

@app.get("/dashboard")
async def get_dashboard(request: Request):
    days_raw = request.query_params.get("days", "30")
    try:
        days = int(days_raw)
    except ValueError:
        return JSONResponse({"error": "days must be 1..365"}, status_code=400)
    days = max(1, min(365, days))

    rows = await get_pool().fetch(DASHBOARD_AGG, days)

    out = [
        "<!doctype html><html><head><title>Bench dashboard</title></head><body>",
        "<h1>Bench dashboard</h1>",
        "<table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>",
    ]
    for r in rows:
        name = html.escape(r["name"])
        out.append(f"<tr><td>{name}</td><td>{r['order_count']}</td><td>{r['total_cents'] / 100.0:.2f}</td></tr>")
    out.append("</tbody></table></body></html>")

    return HTMLResponse(
        "".join(out),
        headers={"Content-Type": "text/html; charset=utf-8"},
        status_code=200,
    )


# ---------------------------------------------------------------------------
# 5. /health -- liveness, no database round trip.
# ---------------------------------------------------------------------------

@app.get("/health")
async def get_health():
    return JSONResponse({"status": "ok"}, status_code=200)


# ---------------------------------------------------------------------------
# 6. /metrics -- Prometheus text format.
# ---------------------------------------------------------------------------

@app.get("/metrics")
async def get_metrics():
    return Response(content=generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST, status_code=200)


# ---------------------------------------------------------------------------
# Launcher.
# ---------------------------------------------------------------------------

def run() -> None:
    port = int(os.environ.get("PORT", "8080"))
    level = os.environ.get("LOG_LEVEL", "warn").lower()
    # access_log is off so LOG_LEVEL=warn produces no per-request logging.
    uvicorn.run(app, host="0.0.0.0", port=port, log_level=level, access_log=False)


if __name__ == "__main__":
    run()
