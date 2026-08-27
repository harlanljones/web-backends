# Results

Published benchmark reports live here, one directory per campaign:
`docs/results/<date>-bench/index.html`.

## How to read a published result

The repository draws a hard line between two kinds of numbers, and that line is
the point of the benchmark:

| Kind | Where it lives | Meaning |
| --- | --- | --- |
| **Bare-metal measurement** | a `docs/results/<date>-bench/` report generated from a conforming, five-trial campaign on the three-node testbed | the framework's actual published numbers |
| **Single-host development run** | `runs/` on the operator's machine (not committed) | a smoke test; the load generator competes with the app for CPU |

## The no-fabrication rule

`bench/analysis/report.py` is a *generator*, not a source of truth. A published
report is produced only from real trial data, never from synthetic numbers. If
a report appears here, its raw inputs are the `runs/<trial-id>/` artifacts the
analysis pipeline consumed — and every trial's `manifest.json` carries the
preflight host report so a reader can verify the testbed actually matched
`docs/benchmark/testbed-hardware.md`.

> Any report carrying a prominent "single-host development result" banner is a
> demonstration of the pipeline, not a measurement. It is retained only to show
> the tooling end to end.

## Generating a report

```bash
python3 bench/analysis/aggregate.py --framework go --runs runs --json > results/go.json
# ... one per framework ...
python3 bench/analysis/compare.py --json-output report.json
python3 bench/analysis/report.py --compare report.json
```

See `bench/analysis/README.md` for the full pipeline.
