// Saturation phase.
//
// 10 minutes at TARGET_RPS per workload, run in parallel across the
// four workloads. This is the measurement. Results are checked against
// SATURATION_THRESHOLDS: a trial whose saturation phase violates any
// threshold is recorded but flagged "failed" in the run manifest.
//
// Usage:
//   k6 run bench/k6/saturation.js
//   TARGET_RPS=10000 k6 run bench/k6/saturation.js

import { stages, startRate, SUMMARY_TREND_STATS, SATURATION_DURATION, TARGET_RPS, SATURATION_THRESHOLDS, WORKLOADS } from './lib/config.js';
import {
  buildScenarios,
  jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload,
} from './lib/endpoints.js';
import { handleSummary } from './lib/output.js';

const satStages = stages('saturation');
console.log(`saturation: ${SATURATION_DURATION} at ${TARGET_RPS} RPS (workloads: ${WORKLOADS.join(',')})`);

// Per-workload thresholds. k6 threshold keys can include tag selectors
// like {workload:json}, which is how we slice the per-scenario metrics.
const thresholds = { 'http_req_failed': SATURATION_THRESHOLDS['http_req_failed'] };
for (const w of WORKLOADS) {
  thresholds[`http_req_duration{workload:${w}}`] = SATURATION_THRESHOLDS['http_req_duration'];
}

export const options = {
  scenarios: buildScenarios(satStages, WORKLOADS, startRate('saturation')),
  thresholds,
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export { handleSummary };

// See warmup.js for why these re-exports exist.
export { jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload };
