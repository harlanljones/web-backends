'use strict';

// Fastify reference implementation of the benchmark contract
// (contracts/openapi.yaml). Four workloads + /health + /metrics.
//
// Reads three env vars at startup and holds them constant:
//   DATABASE_URL   (required)
//   DB_POOL_SIZE   (pool max = exactly this many connections, default 32)
//   PORT           (default 8080)
//   LOG_LEVEL      (default "warn"; at "warn"/"error" no per-request logs)

const fastify = require('fastify');
const { Pool, types } = require('pg');
const { Registry, Histogram } = require('prom-client');

// ---------------------------------------------------------------------------
// bigint handling
// ---------------------------------------------------------------------------
// The schema uses bigint for id / customer_id / product_id / order_id.
// node-postgres returns bigint as a string by default; the contract wants JS
// numbers. Benchmark ids are far below Number.MAX_SAFE_INTEGER, so int8 (OID
// 20) -> Number is safe. COUNT() and ::bigint casts go through the same OID.
types.setTypeParser(20, (v) => Number(v));

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

function getenv(key, fallback) {
  const v = process.env[key];
  return v === undefined || v === '' ? fallback : v;
}

const DATABASE_URL = getenv('DATABASE_URL', '');
const DB_POOL_SIZE = Math.max(1, parseInt(getenv('DB_POOL_SIZE', '32'), 10) || 32);
const PORT = getenv('PORT', '8080');
const LOG_LEVEL = getenv('LOG_LEVEL', 'warn');

if (!DATABASE_URL) {
  throw new Error('DATABASE_URL must be set');
}

// ---------------------------------------------------------------------------
// database pool
// ---------------------------------------------------------------------------

const pool = new Pool({
  connectionString: DATABASE_URL,
  // The contract: the pool opens exactly DB_POOL_SIZE connections, never more.
  // node-postgres has no "min", so we warm the pool up to max below.
  max: DB_POOL_SIZE,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

pool.on('error', (err) => {
  // An idle client errored; don't take the process down for it.
  console.error('pool idle client error', err);
});

// Open exactly DB_POOL_SIZE connections so the pool cannot exceed it during
// the benchmark. A pool sized larger than DB_POOL_SIZE would trip the
// active-connections recording rule and discard the trial.
async function warmPool(n) {
  const clients = [];
  try {
    for (let i = 0; i < n; i += 1) {
      clients.push(await pool.connect());
    }
    await Promise.all(clients.map((c) => c.query('SELECT 1')));
  } finally {
    for (const c of clients) c.release();
  }
}

// ---------------------------------------------------------------------------
// metrics
// ---------------------------------------------------------------------------

const registry = new Registry();
const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'End-to-end request latency, in seconds.',
  labelNames: ['path', 'method', 'status'],
  buckets: [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5],
});
registry.registerMetric(httpRequestDuration);

// Map the route's path template to a workload-name label. Single source of
// truth so a new endpoint only needs registering here and in the router.
// The label is the workload name, not the URL, so it stays low-cardinality.
function workloadName(url) {
  switch (url) {
    case '/json':
      return 'json';
    case '/products/:id':
      return 'product_read';
    case '/orders':
      return 'order_write';
    case '/dashboard':
      return 'dashboard';
    case '/health':
    case '/metrics':
      return 'infra';
    default:
      return 'other';
  }
}

// Pre-warm a series per workload so /metrics always emits the histogram
// family (the conformance runner greps for _bucket) even on its first call.
(/* initialize a zero series for each workload */ function seedMetrics() {
  httpRequestDuration.labels('json', 'GET', '200').observe(0);
  httpRequestDuration.labels('product_read', 'GET', '200').observe(0);
  httpRequestDuration.labels('product_read', 'GET', '404').observe(0);
  httpRequestDuration.labels('order_write', 'POST', '201').observe(0);
  httpRequestDuration.labels('order_write', 'POST', '409').observe(0);
  httpRequestDuration.labels('dashboard', 'GET', '200').observe(0);
  httpRequestDuration.labels('infra', 'GET', '200').observe(0);
}());

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Read an existing order by idempotency key (the replay path). Uses the pool,
// not a transaction: the original order was already committed.
async function replayOrder(idemKey) {
  const { rows } = await pool.query(
    `SELECT id, customer_id, status::text AS status, total_cents
       FROM orders
      WHERE idempotency_key = $1`,
    [idemKey],
  );
  if (rows.length === 0) {
    return { code: 500, body: { error: 'internal error' } };
  }
  const o = rows[0];
  const items = await pool.query(
    'SELECT product_id, quantity, unit_price_cents FROM order_items WHERE order_id = $1',
    [o.id],
  );
  return {
    code: 201,
    body: {
      id: o.id,
      customer_id: o.customer_id,
      status: o.status,
      total_cents: o.total_cents,
      items: items.rows,
    },
  };
}

// ---------------------------------------------------------------------------
// server / hooks
// ---------------------------------------------------------------------------

const app = fastify({
  // LOG_LEVEL controls pino. At "warn" (the contract default) the info-level
  // per-request logs Fastify emits are dropped, keeping the log budget intact.
  logger: { level: LOG_LEVEL },
});

// Timestamp each request and record the latency histogram after the response.
app.addHook('onRequest', (req, _reply, done) => {
  req._start = process.hrtime.bigint();
  done();
});

app.addHook('onResponse', (req, reply, done) => {
  const elapsedNs = process.hrtime.bigint() - req._start;
  const seconds = Number(elapsedNs) / 1e9;
  const url = (req.routeOptions && req.routeOptions.url) || req.raw.url;
  const status = String(reply.statusCode);
  httpRequestDuration.labels(workloadName(url), req.raw.method, status).observe(seconds);
  done();
});

// ---------------------------------------------------------------------------
// /json
// ---------------------------------------------------------------------------

app.get('/json', async () => ({
  service: 'bench',
  version: '1.0.0',
  time: new Date().toISOString(),
}));

// ---------------------------------------------------------------------------
// /health  (no DB round trip)
// ---------------------------------------------------------------------------

app.get('/health', async () => ({ status: 'ok' }));

// ---------------------------------------------------------------------------
// /products/:id
// ---------------------------------------------------------------------------

app.get('/products/:id', async (req, reply) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) {
    return reply.code(400).send({ error: 'invalid id' });
  }
  const { rows } = await pool.query(
    `SELECT id, sku, name, description, category_id, price_cents, stock, active
       FROM products
      WHERE id = $1`,
    [id],
  );
  if (rows.length === 0) {
    return reply.code(404).send({ error: 'not found' });
  }
  return rows[0];
});

// ---------------------------------------------------------------------------
// /orders
// ---------------------------------------------------------------------------

app.post('/orders', async (req, reply) => {
  const idemKey = req.headers['idempotency-key'];
  if (!idemKey) {
    return reply.code(400).send({ error: 'Idempotency-Key header is required' });
  }

  const body = req.body || {};
  const customerId = body.customer_id;
  const items = body.items;
  if (!Number.isInteger(customerId) || !Array.isArray(items) || items.length === 0) {
    return reply.code(400).send({ error: 'invalid body' });
  }

  // Lock product rows in sorted id order to avoid deadlocks under concurrent
  // overlapping requests. Dedup so a product touched twice is locked once.
  const productIDs = [...new Set(items.map((i) => i.product_id))].sort((a, b) => a - b);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const prices = new Map();
    for (const pid of productIDs) {
      const { rows } = await client.query(
        'SELECT price_cents, stock FROM products WHERE id = $1 FOR UPDATE',
        [pid],
      );
      if (rows.length === 0) {
        await client.query('ROLLBACK');
        client.release();
        return reply.code(400).send({ error: 'unknown product', details: { product_id: pid } });
      }
      prices.set(pid, rows[0]);
    }

    let total = 0;
    for (const it of items) {
      const p = prices.get(it.product_id);
      if (!p) {
        await client.query('ROLLBACK');
        client.release();
        return reply.code(400).send({
          error: 'unknown product',
          details: { product_id: it.product_id },
        });
      }
      if (p.stock < it.quantity) {
        await client.query('ROLLBACK');
        client.release();
        return reply.code(409).send({
          error: 'insufficient stock',
          details: {
            product_id: it.product_id,
            available: p.stock,
            requested: it.quantity,
          },
        });
      }
      total += p.price_cents * it.quantity;
    }

    const ins = await client.query(
      `INSERT INTO orders (customer_id, status, total_cents, idempotency_key)
            VALUES ($1, 'pending', $2, $3)
       ON CONFLICT (idempotency_key) DO NOTHING
            RETURNING id`,
      [customerId, total, idemKey],
    );

    if (ins.rows.length === 0) {
      // Replay of an existing key. Roll back the (read-only) transaction and
      // return the original order with its original id.
      await client.query('ROLLBACK');
      client.release();
      const r = await replayOrder(idemKey);
      return reply.code(r.code).send(r.body);
    }

    const orderId = ins.rows[0].id;

    for (const it of items) {
      const p = prices.get(it.product_id);
      await client.query(
        `INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents)
              VALUES ($1, $2, $3, $4)`,
        [orderId, it.product_id, it.quantity, p.price_cents],
      );
      await client.query(
        'INSERT INTO inventory_ledger (product_id, order_id, delta) VALUES ($1, $2, $3)',
        [it.product_id, orderId, -it.quantity],
      );
      await client.query(
        'UPDATE products SET stock = stock - $1, updated_at = now() WHERE id = $2',
        [it.quantity, it.product_id],
      );
    }

    await client.query('COMMIT');
    client.release();

    const outItems = items.map((it) => ({
      product_id: it.product_id,
      quantity: it.quantity,
      unit_price_cents: prices.get(it.product_id).price_cents,
    }));
    return reply.code(201).send({
      id: orderId,
      customer_id: customerId,
      status: 'pending',
      total_cents: total,
      items: outItems,
    });
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (_e) {
      /* ignore */
    }
    client.release();
    throw err;
  }
});

// ---------------------------------------------------------------------------
// /dashboard
// ---------------------------------------------------------------------------

app.get('/dashboard', async (req, reply) => {
  let days = 30;
  if (req.query && req.query.days !== undefined) {
    const n = Number(req.query.days);
    if (Number.isFinite(n) && Number.isInteger(n)) {
      days = n;
    }
  }
  // Clamp to the contract range 1..365.
  days = Math.min(365, Math.max(1, days));

  const { rows } = await pool.query(
    `SELECT
        c.id,
        c.name,
        COUNT(o.id)                    AS order_count,
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
     ORDER BY c.id`,
    [days],
  );

  let body =
    '<!doctype html><html><head><title>Bench dashboard</title></head><body>' +
    '<h1>Bench dashboard</h1>' +
    '<table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>';
  for (const r of rows) {
    body += `<tr><td>${escapeHtml(r.name)}</td>` +
      `<td>${r.order_count}</td>` +
      `<td>${(r.total_cents / 100).toFixed(2)}</td></tr>`;
  }
  body += '</tbody></table></body></html>';

  return reply.type('text/html; charset=utf-8').send(body);
});

// ---------------------------------------------------------------------------
// /metrics
// ---------------------------------------------------------------------------

app.get('/metrics', async (_req, reply) => {
  reply.type('text/plain; version=0.0.4');
  return registry.metrics();
});

// ---------------------------------------------------------------------------
// start
// ---------------------------------------------------------------------------

async function main() {
  await warmPool(DB_POOL_SIZE);
  app.log.info(
    { framework: 'node-fastify', db_pool_size: DB_POOL_SIZE, port: PORT, log_level: LOG_LEVEL },
    'starting bench app',
  );
  app.log.info('database pool ready');

  await app.listen({ port: Number(PORT), host: '0.0.0.0' });
}

main().catch((err) => {
  app.log.error({ err }, 'startup failed');
  process.exit(1);
});
