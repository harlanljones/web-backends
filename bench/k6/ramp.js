// Ramp phase.
//
// 10 minutes ramping from RAMP_START_RPS to TARGET_RPS in RAMP_STAGES
// equal steps. Each workload ramps in parallel. The ramp's purpose is
// to find the framework's saturation point -- the highest RPS at which
// it can sustain the saturation thresholds -- so the saturation phase
// is at a defensible level, not a guess.
//
// Usage:
//   k6 run bench/k6/ramp.js
//   TARGET_RPS=12000 RAMP_END_RPS=12000 k6 run bench/k6/ramp.js

import { stages, RAMP_DURATION, RAMP_START_RPS, RAMP_END_RPS, RAMP_STAGES } from './lib/config.js';
import {
  jsonScenario, productReadScenario, orderWriteScenario, dashboardScenario,
  jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload,
} from './lib/endpoints.js';
import { handleSummary } from './lib/output.js';

const rampStages = stages('ramp');
console.log(`ramp: ${RAMP_DURATION} from ${RAMP_START_RPS} to ${RAMP_END_RPS} RPS in ${RAMP_STAGES} stages`);

// No thresholds on the ramp either. The whole point of the ramp is
// to discover where the framework's p99.9 crosses our threshold; that
// is a number we want to record, not a failure to fail on.
export const options = {
  scenarios: Object.assign(
    {},
    jsonScenario(rampStages),
    productReadScenario(rampStages),
    orderWriteScenario(rampStages),
    dashboardScenario(rampStages),
  ),
  thresholds: {},
};

export { handleSummary };

// See warmup.js for why these re-exports exist.
export { jsonWorkload, productReadWorkload, orderWriteWorkload, dashboardWorkload };
