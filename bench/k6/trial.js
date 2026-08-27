// One-shot: run the full three-phase protocol (warmup -> ramp -> saturation)
// as a single k6 invocation. This is what `bench/scripts/run-trial.sh` calls
// for a single trial.
//
// Equivalent to running the three phase scripts back-to-back; the
// difference is that this script does the bookkeeping in one summary
// file, which the run manifest can point at.
//
// Usage:
//   k6 run bench/k6/trial.js
//   TARGET_RPS=10000 k6 run bench/k6/trial.js

import { stages, startRate, SUMMARY_TREND_STATS, TARGET_RPS, WORKLOADS } from './lib/config.js';
import {
  buildScenarios,
  jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload,
} from './lib/endpoints.js';
import { handleSummary } from './lib/output.js';

const satStages = stages('saturation');

console.log(`trial: warmup -> ramp -> saturation, peak ${TARGET_RPS} RPS (workloads: ${WORKLOADS.join(',')})`);

export const options = {
  scenarios: buildScenarios(satStages, WORKLOADS, startRate('saturation')),
  thresholds: {},
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export { handleSummary };

// See warmup.js for why these re-exports exist.
export { jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload };
