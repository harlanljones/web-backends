// Warm-up phase.
//
// 3 minutes at 20% of TARGET_RPS per workload, run in parallel across
// the four workloads. Total time: 3 minutes (the workloads are
// concurrent).
//
// The warm-up's job is to bring the framework's connection pool to its
// target size, the database's plan cache to its steady state, and the
// OS page cache to the seed set. Results are written to /runs but are
// not used for measurement.
//
// Usage:
//   k6 run bench/k6/warmup.js
//   TARGET_RPS=10000 k6 run bench/k6/warmup.js

import { stages, WARMUP_DURATION, TARGET_RPS, WARMUP_RPS_FRAC } from './lib/config.js';
import {
  jsonScenario, productReadScenario, orderWriteScenario, dashboardScenario,
  jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload,
} from './lib/endpoints.js';
import { handleSummary } from './lib/output.js';

const warmupStages = stages('warmup');
const warmupRps = Math.round(TARGET_RPS * WARMUP_RPS_FRAC);
console.log(`warmup: ${WARMUP_DURATION} at ${warmupRps} RPS per workload`);

// No thresholds on warm-up: we are not measuring yet, and a framework
// that runs out of headroom during warm-up is a finding we want to
// record in the run manifest, not a failure of the k6 script.
export const options = {
  scenarios: Object.assign(
    {},
    jsonScenario(warmupStages),
    productReadScenario(warmupStages),
    orderWriteScenario(warmupStages),
    dashboardScenario(warmupStages),
  ),
  thresholds: {},
};

export { handleSummary };

// k6's scenario `exec` looks up the function in this file's exports.
// The implementations live in lib/endpoints.js; re-export them here so
// the static analyzer finds them.
export { jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload };
