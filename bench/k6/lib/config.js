// k6 protocol configuration.
//
// Every phase reads TARGET_RPS and the per-phase duration from environment
// variables. Defaults match the project description in
// docs/benchmark/testbed.md, but the operator can override them on the
// command line (`k6 run --env TARGET_RPS=5000 ...`).
//
// Why environment variables and not a config file: k6 scripts are
// read-only inside the loadgen container, and the trial driver composes
// k6 invocations with the per-trial numbers. A config file would have
// to be regenerated per run; env vars just work.

export const TARGET_BASE_URL = __ENV.TARGET_BASE_URL || 'http://app:8080';

// Which workloads a phase runs. Comma-separated subset of the four
// workload names. Defaults to all four. A read-only benchmark sets
// WORKLOADS=json,product_read (no writes, no seed mutation).
export const WORKLOADS = (__ENV.WORKLOADS || 'json,product_read,order_write,dashboard')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

// Phases
// -------
// WARMUP   3 minutes at 20% of the trial's RPS. Lets the database
//          plan cache and the framework's connection pool reach a
//          steady state before measurement starts.
//
// RAMP     10 minutes ramping from RAMP_START_RPS to TARGET_RPS in
//          RAMP_STAGES steps. Default 500 -> 10000 over 10 stages
//          gives a 1-minute stage. The ramp's results are not used
//          for measurement; they exist so a saturation trial's
//          "we hit N RPS at the cap" has a defensible N.
//
// SATURATION
//          10 minutes at TARGET_RPS. This is the measurement. The
//          k6 thresholds (p99, error rate) on this phase are what
//          decide whether the trial is publishable.

export const WARMUP_DURATION    = __ENV.WARMUP_DURATION    || '3m';
export const WARMUP_RPS_FRAC    = Number(__ENV.WARMUP_RPS_FRAC || 0.2);

export const RAMP_DURATION      = __ENV.RAMP_DURATION      || '10m';
export const RAMP_START_RPS     = Number(__ENV.RAMP_START_RPS || 500);
export const RAMP_END_RPS       = Number(__ENV.RAMP_END_RPS   || 10000);
export const RAMP_STAGES        = Number(__ENV.RAMP_STAGES     || 10);

export const SATURATION_DURATION = __ENV.SATURATION_DURATION || '10m';
export const TARGET_RPS         = Number(__ENV.TARGET_RPS || 10000);

// The published targets in the project description: peak RPS, p50, p95,
// p99, p99.9, and error rate. Thresholds are enforced on the saturation
// phase; a trial whose saturation phase violates any of these is
// recorded but flagged "failed" in the run manifest.
export const SATURATION_THRESHOLDS = {
  // Error rate. The benchmark is meant to measure under-load behavior;
  // a 1% error rate is the limit beyond which we are not measuring
  // the framework but the framework giving up.
  'http_req_failed':   ['rate<0.01'],
  // p99.9 is what tail-latency-conscious users care about. A
  // framework whose p99.9 is in seconds is not a viable candidate.
  'http_req_duration': ['p(99.9)<1000'],
};

// Trend percentiles k6 must compute for the summary. The default set is
// ['avg','min','med','max','p(90)','p(95)']; the benchmark's headline
// p99/p99.9 (and aggregate.py) need the longer list, so it is set
// explicitly on every phase.
export const SUMMARY_TREND_STATS = ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)'];

// Per-VU request rate. k6's open-model arrival-rate executor targets
// a fixed rate; the VU pool is sized so the rate is achievable with
// some headroom for retries. The ratio of VU to RPS is per-workload
// because /json needs fewer VUs than /orders to sustain the same
// rate.
export const VU_POOL = {
  json:         { min: 50,  max: 200  },
  product_read: { min: 50,  max: 400  },
  order_write:  { min: 100, max: 800  },
  dashboard:    { min: 50,  max: 200  },
};

// Stages are passed to k6's `ramping-arrival-rate` executor. Each
// stage is { duration, target }. The ramp phase has RAMP_STAGES
// stages; the saturation phase has one stage; the warmup phase has
// one stage.
export function stages(phase /* 'warmup' | 'ramp' | 'saturation' */) {
  switch (phase) {
    case 'warmup':
      return [{ duration: WARMUP_DURATION, target: Math.round(TARGET_RPS * WARMUP_RPS_FRAC) }];
    case 'ramp': {
      const out = [];
      const stepRps = (RAMP_END_RPS - RAMP_START_RPS) / RAMP_STAGES;
      const stepDur = parseDuration(RAMP_DURATION) / RAMP_STAGES;
      for (let i = 1; i <= RAMP_STAGES; i++) {
        out.push({ duration: formatDuration(stepDur), target: Math.round(RAMP_START_RPS + stepRps * i) });
      }
      return out;
    }
    case 'saturation':
      return [{ duration: SATURATION_DURATION, target: TARGET_RPS }];
  }
  throw new Error(`unknown phase: ${phase}`);
}

// The iteration start rate for a phase's FIRST stage. `ramping-arrival-rate`
// ramps linearly from `startRate` (default 0) to the first stage's `target`,
// so a single-stage warmup/saturation must set `startRate` equal to its target
// or it will average half the intended rate. The ramp phase starts at its
// ramp floor rather than 0.
export function startRate(phase /* 'warmup' | 'ramp' | 'saturation' */) {
  switch (phase) {
    case 'warmup':
      return Math.round(TARGET_RPS * WARMUP_RPS_FRAC);
    case 'ramp':
      return RAMP_START_RPS;
    case 'saturation':
      return TARGET_RPS;
  }
  return 0;
}

// Parse a k6 duration like "3m" or "30s" into seconds. Used to derive
// per-stage durations for the ramp.
function parseDuration(s) {
  const m = String(s).match(/^(\d+(?:\.\d+)?)([smh])$/);
  if (!m) throw new Error(`invalid duration: ${s}`);
  const n = parseFloat(m[1]);
  switch (m[2]) {
    case 's': return n;
    case 'm': return n * 60;
    case 'h': return n * 3600;
  }
  return 0;
}

function formatDuration(seconds) {
  // k6 accepts "Ns" for whole seconds; for non-integer seconds use
  // fractional, which k6 also accepts.
  return `${seconds}s`;
}
