// The four workload scenarios, each as a small named function so the
// phase orchestrators can compose them.
//
// The scenarios use k6's `ramping-arrival-rate` executor with
// preAllocatedVUs / maxVUs sized from VU_POOL. The default check()
// function rejects responses that don't match the contract status code;
// framework-specific contract violations (e.g. JSON shape) are not
// asserted at the load-generation layer because the conformance runner
// has already done that work before the trial.
//
// All scenarios tag their metrics with `workload: <name>`, so per-workload
// thresholds can be written in the orchestrator's top-level `thresholds`
// block as `http_req_duration{workload:json}` etc.

import http from 'k6/http';
import { check, fail } from 'k6';
import { TARGET_BASE_URL, VU_POOL } from './config.js';

// ---------------------------------------------------------------------------
// /json
// ---------------------------------------------------------------------------

export function jsonScenario(stages) {
  return {
    json: {
      executor: 'ramping-arrival-rate',
      stages,
      preAllocatedVUs: VU_POOL.json.min,
      maxVUs: VU_POOL.json.max,
      timeUnit: '1s',
      exec: 'jsonWorkload',
      tags: { workload: 'json' },
    },
  };
}

export function jsonWorkload() {
  const res = http.get(`${TARGET_BASE_URL}/json`, {
    tags: { workload: 'json' },
  });
  const ok = check(res, {
    'json: status 200': (r) => r.status === 200,
    'json: has service field': (r) => {
      try { return r.json('service') === 'bench'; } catch (e) { return false; }
    },
  });
  if (!ok) fail('json workload check failed');
}

// ---------------------------------------------------------------------------
// /products/:id
// ---------------------------------------------------------------------------

export function productReadScenario(stages) {
  return {
    product_read: {
      executor: 'ramping-arrival-rate',
      stages,
      preAllocatedVUs: VU_POOL.product_read.min,
      maxVUs: VU_POOL.product_read.max,
      timeUnit: '1s',
      exec: 'productReadWorkload',
      tags: { workload: 'product_read' },
    },
  };
}

export function productReadWorkload() {
  // Random product id in the seeded range. The seed sizes
  // SEED_PRODUCTS (default 100k) products; ids are 1..SEED_PRODUCTS.
  // Math.random() is the right distribution here: every trial sees
  // the same id distribution in expectation, but no single product
  // is hot enough to be a cache.
  const id = 1 + Math.floor(Math.random() * 100000);
  const res = http.get(`${TARGET_BASE_URL}/products/${id}`, {
    tags: { workload: 'product_read' },
  });
  // 200 (found) or 404 (no rows) are both contract-compliant.
  // Anything else is a framework bug.
  const ok = check(res, {
    'product_read: status 200 or 404': (r) => r.status === 200 || r.status === 404,
  });
  if (!ok) fail(`product_read returned ${res.status}`);
}

// ---------------------------------------------------------------------------
// /orders
// ---------------------------------------------------------------------------

export function orderWriteScenario(stages) {
  return {
    order_write: {
      executor: 'ramping-arrival-rate',
      stages,
      preAllocatedVUs: VU_POOL.order_write.min,
      maxVUs: VU_POOL.order_write.max,
      timeUnit: '1s',
      exec: 'orderWriteWorkload',
      tags: { workload: 'order_write' },
    },
  };
}

let orderCounter = 0;
export function orderWriteWorkload() {
  // Each iteration creates a new order. The customer and products are
  // sampled from the seeded range; the Idempotency-Key is unique per
  // iteration so we are not testing the replay path here (that has its
  // own test in the conformance runner).
  //
  // Note: this is the workload's *write* path. A framework that
  // happens to cache the response would still be measured honestly
  // because each request has a different Idempotency-Key and a
  // different body.
  orderCounter += 1;
  const idem = `${__VU}-${__ITER}-${Date.now()}-${orderCounter}`;
  const customerId = 1 + Math.floor(Math.random() * 50000);
  // Two items per order, matching the conformance test.
  const item1 = 1 + Math.floor(Math.random() * 100000);
  const item2 = 1 + Math.floor(Math.random() * 100000);
  const body = JSON.stringify({
    customer_id: customerId,
    items: [
      { product_id: item1, quantity: 1 },
      { product_id: item2, quantity: 1 },
    ],
  });
  const res = http.post(`${TARGET_BASE_URL}/orders`, body, {
    headers: {
      'Content-Type': 'application/json',
      'Idempotency-Key': idem,
    },
    tags: { workload: 'order_write' },
  });
  const ok = check(res, {
    'order_write: status 201': (r) => r.status === 201,
  });
  if (!ok) fail(`order_write returned ${res.status} body=${(res.body || '').slice(0, 200)}`);
}

// ---------------------------------------------------------------------------
// /dashboard
// ---------------------------------------------------------------------------

export function dashboardScenario(stages) {
  return {
    dashboard: {
      executor: 'ramping-arrival-rate',
      stages,
      preAllocatedVUs: VU_POOL.dashboard.min,
      maxVUs: VU_POOL.dashboard.max,
      timeUnit: '1s',
      exec: 'dashboardWorkload',
      tags: { workload: 'dashboard' },
    },
  };
}

export function dashboardWorkload() {
  const res = http.get(`${TARGET_BASE_URL}/dashboard?days=30`, {
    tags: { workload: 'dashboard' },
  });
  const ok = check(res, {
    'dashboard: status 200': (r) => r.status === 200,
    'dashboard: content-type text/html': (r) => {
      const ct = r.headers['Content-Type'] || '';
      return ct.includes('text/html');
    },
    'dashboard: contains <table>': (r) => typeof r.body === 'string' && r.body.includes('<table'),
  });
  if (!ok) fail(`dashboard check failed status=${res.status}`);
}

// ---------------------------------------------------------------------------
// Scenario composition
// ---------------------------------------------------------------------------

const SCENARIO_BUILDERS = {
  json: jsonScenario,
  product_read: productReadScenario,
  order_write: orderWriteScenario,
  dashboard: dashboardScenario,
};

// Build the k6 `scenarios` object for exactly the workloads in `workloads`
// (a subset of the four names), each at the given arrival-rate `stages` and
// initial `startRate`. Unknown names are ignored so a typo degrades to
// "fewer workloads" rather than a k6 startup error.
export function buildScenarios(stages, workloads, startRate) {
  const out = {};
  for (const w of workloads) {
    const builder = SCENARIO_BUILDERS[w];
    if (!builder) continue;
    const built = builder(stages);
    if (startRate !== undefined) {
      for (const name of Object.keys(built)) {
        built[name].startRate = startRate;
      }
    }
    Object.assign(out, built);
  }
  return out;
}
