// k6 result archival.
//
// k6 emits a JSON summary on completion; we save it to /runs/<trial>/
// inside the loadgen container. The trial driver (`bench/scripts/run-trial.sh`)
// bind-mounts ./runs there so the summary lands on the host filesystem.
//
// The summary is the trial's "result" -- everything else in the
// run manifest (preflight JSON, hardware specs, pg_stat_statements
// snapshot) is environment context, not result.

import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.3/index.js';

export function handleSummary(data) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const out = {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    [`/runs/${stamp}-summary.json`]: JSON.stringify(data, null, 2),
    [`/runs/${stamp}-summary.txt`]: textSummary(data, { indent: '  ' }),
  };
  return out;
}
