// Hono on Bun reference implementation of the benchmark contract.
//
// Implements the four workloads + /health + /metrics against
// contracts/openapi.yaml, using Hono for routing, postgres.js for the
// connection pool, and prom-client for the contracted histogram.
//
// Deliberately not done:
//   * No caching. /products/:id hits PostgreSQL every request.
//   * No extra pool. postgres.js's `max` is the only pool; the contract
//     forbids a second pool layered on top.
//   * No per-request logging. At LOG_LEVEL=warn nothing is emitted per
//     request, so the log budget stays within the contract.
//
// Concurrency model: Bun's event loop plus postgres.js's connection pool.
// The pool opens at most DB_POOL_SIZE connections; each request borrows one
// (a transaction borrows one for its whole lifetime). No per-request
// threads or goroutine pools — Hono handlers are async and the event loop
// multiplexes them onto the pool.

import { Hono } from "hono";
import postgres from "postgres";
import { Registry, Histogram } from "prom-client";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const LOG_LEVEL = (process.env.LOG_LEVEL || "warn").toLowerCase() as
  | "error"
  | "warn"
  | "info"
  | "debug";

const LEVEL: Record<string, number> = { debug: 20, info: 30, warn: 40, error: 50 };
const currentLevel = LEVEL[LOG_LEVEL] ?? LEVEL.warn;

function log(level: "info" | "error", msg: string, fields: Record<string, unknown> = {}) {
  if ((LEVEL[level] ?? LEVEL.info) >= currentLevel) {
    process.stderr.write(JSON.stringify({ level, msg, ...fields }) + "\n");
  }
}

function required(varName: string): string {
  const v = process.env[varName];
  if (!v) {
    log("error", "startup failed", { err: `${varName} must be set` });
    process.exit(1);
  }
  return v;
}

const databaseUrl = required("DATABASE_URL");
const port = Number(process.env.PORT || 8080);
let dbPoolSize = Number(process.env.DB_POOL_SIZE || 32);
if (!Number.isInteger(dbPoolSize) || dbPoolSize <= 0) {
  log("error", "startup failed", { err: "DB_POOL_SIZE must be a positive integer" });
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Database pool (postgres.js). `max` is the pool size: the contract requires
// exactly DB_POOL_SIZE connections and no pool on top of this one.
// ---------------------------------------------------------------------------

const sql = postgres(databaseUrl, { max: dbPoolSize });

// ---------------------------------------------------------------------------
// Metrics — the contracted Prometheus histogram.
//
// `path` is normalized to the workload name, not the request URL pattern, so
// /products/1 and /products/999 are both `product_read`. That keeps the label
// low-cardinality across every framework. The bucket layout matches the
// Go/Rust references (sub-millisecond to 5s).
// ---------------------------------------------------------------------------

const registry = new Registry();
const httpRequestDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "End-to-end request latency, in seconds.",
  labelNames: ["path", "method", "status"],
  buckets: [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5],
  registers: [registry],
});

function workloadName(path: string): string {
  if (path === "/json") return "json";
  if (path.startsWith("/products/")) return "product_read";
  if (path === "/orders") return "order_write";
  if (path === "/dashboard") return "dashboard";
  if (path === "/health" || path === "/metrics") return "infra";
  return "other";
}

const app = new Hono();

// ---------------------------------------------------------------------------
// Middleware — record the workload-labeled latency histogram.
// ---------------------------------------------------------------------------
app.use("*", async (c, next) => {
  const start = performance.now();
  await next();
  const route = c.req.routePath || c.req.path;
  const path = workloadName(route);
  const method = c.req.method;
  const status = String(c.res.status);
  httpRequestDuration.labels(path, method, status).observe((performance.now() - start) / 1000);
});

// ---------------------------------------------------------------------------
// 1. GET /json — I/O-free serialization.
// ---------------------------------------------------------------------------
app.get("/json", (c) => {
  return c.json({ service: "bench", version: "1.0.0", time: new Date().toISOString() });
});

// ---------------------------------------------------------------------------
// 2. GET /products/:id — indexed single-record read.
// ---------------------------------------------------------------------------
app.get("/products/:id", async (c) => {
  const id = Number(c.req.param("id"));
  if (!Number.isInteger(id) || id <= 0) {
    return c.json({ error: "invalid id" }, 400);
  }
  const rows = await sql`
    SELECT id, sku, name, description, category_id, price_cents, stock, active
    FROM products
    WHERE id = ${id}
  `;
  if (rows.length === 0) {
    return c.json({ error: "not found" }, 404);
  }
  const p = rows[0];
  return c.json({
    id: Number(p.id),
    sku: p.sku,
    name: p.name,
    description: p.description,
    category_id: Number(p.category_id),
    price_cents: Number(p.price_cents),
    stock: Number(p.stock),
    active: p.active,
  });
});

// ---------------------------------------------------------------------------
// 3. POST /orders — transactional multi-table write.
// ---------------------------------------------------------------------------
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

app.post("/orders", async (c) => {
  const idemKey = c.req.header("Idempotency-Key");
  if (!idemKey) {
    return c.json({ error: "Idempotency-Key header is required" }, 400);
  }
  if (!UUID_RE.test(idemKey)) {
    return c.json({ error: "invalid Idempotency-Key" }, 400);
  }

  let body: any;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid body", details: { reason: "expected JSON" } }, 400);
  }

  const customerId = body.customer_id;
  const items = body.items;
  if (!Number.isInteger(customerId) || customerId <= 0 || !Array.isArray(items) || items.length === 0) {
    return c.json(
      { error: "invalid body", details: { reason: "customer_id and a non-empty items array are required" } },
      400,
    );
  }
  for (const it of items) {
    if (!Number.isInteger(it.product_id) || !Number.isInteger(it.quantity) || it.quantity <= 0) {
      return c.json(
        { error: "invalid body", details: { reason: "each item needs product_id and quantity" } },
        400,
      );
    }
  }

  const result = await sql.begin(async (tx) => {
    // Lock product rows in sorted, de-duplicated id order. A stable order
    // across requests avoids deadlock when two requests touch overlapping
    // product sets in different orders.
    const productIds = [...new Set(items.map((i: any) => i.product_id))].sort((a: number, b: number) => a - b);
    const prices = new Map<number, { price: number; stock: number }>();

    for (const pid of productIds) {
      const rows = await tx`
        SELECT price_cents, stock FROM products WHERE id = ${pid} FOR UPDATE
      `;
      if (rows.length === 0) {
        return { error: { status: 400, body: { error: "unknown product", product_id: pid } } };
      }
      prices.set(pid, { price: Number(rows[0].price_cents), stock: Number(rows[0].stock) });
    }

    // Check stock and compute the total.
    let total = 0;
    for (const it of items) {
      const p = prices.get(it.product_id);
      if (!p) {
        return { error: { status: 400, body: { error: "unknown product", product_id: it.product_id } } };
      }
      if (p.stock < it.quantity) {
        return {
          error: {
            status: 409,
            body: { error: "insufficient stock", product_id: it.product_id, available: p.stock, requested: it.quantity },
          },
        };
      }
      total += p.price * it.quantity;
    }

    // Insert the order. A duplicate idempotency_key is the replay case: the
    // unique constraint makes the insert a no-op (no row returned).
    const inserted = await tx`
      INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
      VALUES (${customerId}, 'pending', ${total}, ${idemKey}::uuid)
      ON CONFLICT (idempotency_key) DO NOTHING
      RETURNING id
    `;
    if (inserted.length === 0) {
      return { replay: true };
    }
    const orderId = Number(inserted[0].id);

    // Insert items, ledger rows, and decrement stock. The product rows are
    // already locked, so the decrement is atomic.
    for (const it of items) {
      const p = prices.get(it.product_id)!;
      await tx`
        INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents)
        VALUES (${orderId}, ${it.product_id}, ${it.quantity}, ${p.price})
      `;
      await tx`
        INSERT INTO inventory_ledger (product_id, order_id, delta)
        VALUES (${it.product_id}, ${orderId}, ${-it.quantity})
      `;
      await tx`
        UPDATE products SET stock = stock - ${it.quantity}, updated_at = now()
        WHERE id = ${it.product_id}
      `;
    }

    const respItems = items.map((it: any) => ({
      product_id: it.product_id,
      quantity: it.quantity,
      unit_price_cents: prices.get(it.product_id)!.price,
    }));
    return { created: true, orderId, customerId, total, items: respItems };
  });

  if (result.replay) {
    return replayOrder(c, idemKey);
  }
  if (result.error) {
    return c.json(result.error.body, result.error.status as 400 | 409);
  }
  return c.json(
    {
      id: result.orderId,
      customer_id: result.customerId,
      status: "pending",
      total_cents: result.total,
      items: result.items,
    },
    201,
  );
});

async function replayOrder(c: any, idemKey: string) {
  const rows = await sql`
    SELECT id, customer_id, status::text, total_cents
    FROM orders WHERE idempotency_key = ${idemKey}::uuid
  `;
  if (rows.length === 0) {
    return c.json({ error: "internal error" }, 500);
  }
  const r = rows[0];
  const items = await sql`
    SELECT product_id, quantity, unit_price_cents
    FROM order_items WHERE order_id = ${Number(r.id)}
  `;
  return c.json(
    {
      id: Number(r.id),
      customer_id: Number(r.customer_id),
      status: r.status,
      total_cents: Number(r.total_cents),
      items: items.map((i: any) => ({
        product_id: Number(i.product_id),
        quantity: Number(i.quantity),
        unit_price_cents: Number(i.unit_price_cents),
      })),
    },
    201,
  );
}

// ---------------------------------------------------------------------------
// 4. GET /dashboard — aggregation + server-side rendered HTML.
// ---------------------------------------------------------------------------
app.get("/dashboard", async (c) => {
  let days = 30;
  const q = c.req.query("days");
  if (q !== undefined && q !== "") {
    const n = Number(q);
    if (Number.isInteger(n)) {
      days = Math.min(365, Math.max(1, n));
    }
    // Non-integer/NaN days fall back to the default (30).
  }

  const rows = await sql`
    SELECT
      c.id,
      c.name,
      COUNT(o.id)         AS order_count,
      COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents
    FROM categories c
    LEFT JOIN orders o
      ON o.status IN ('paid', 'shipped')
      AND o.created_at >= now() - (${days}::int || ' days')::interval
      AND EXISTS (
        SELECT 1 FROM order_items oi
        JOIN products p ON p.id = oi.product_id
        WHERE oi.order_id = o.id AND p.category_id = c.id
      )
    GROUP BY c.id, c.name
    ORDER BY c.id
  `;

  c.header("Content-Type", "text/html; charset=utf-8");
  const esc = (s: string) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  let body = "<!doctype html><html><head><title>Bench dashboard</title></head><body>"
    + "<h1>Bench dashboard</h1>"
    + "<table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>";
  for (const r of rows) {
    const orderCount = Number(r.order_count);
    const totalCents = Number(r.total_cents);
    body += `<tr><td>${esc(r.name)}</td><td>${orderCount}</td><td>${(totalCents / 100).toFixed(2)}</td></tr>`;
  }
  body += "</tbody></table></body></html>";
  return c.body(body, 200);
});

// ---------------------------------------------------------------------------
// 5. GET /health — liveness. No DB round trip.
// ---------------------------------------------------------------------------
app.get("/health", (c) => c.json({ status: "ok" }));

// ---------------------------------------------------------------------------
// 6. GET /metrics — Prometheus text format.
// ---------------------------------------------------------------------------
app.get("/metrics", async (c) => {
  c.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
  return c.body(await registry.metrics());
});

// ---------------------------------------------------------------------------
// Startup — bring the pool up before serving so /health reflects a
// database-backed process, then listen on PORT.
// ---------------------------------------------------------------------------
async function main() {
  try {
    await sql`SELECT 1`;
  } catch (err) {
    log("error", "startup failed", { err: String(err) });
    process.exit(1);
  }
  log("info", "database pool ready", { db_pool_size: dbPoolSize });

  const server = Bun.serve({
    hostname: "0.0.0.0",
    port,
    fetch: app.fetch,
  });
  log("info", "listening", { addr: `0.0.0.0:${port}` });

  const shutdown = () => {
    log("info", "shutdown signal received");
    server.stop(true);
    sql.end();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main();
