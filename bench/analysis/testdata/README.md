# Analysis test fixture

Synthetic, minimal trial directories used by the CI [`pipeline`][ci] job to
exercise `aggregate.py` → `compare.py` → `report.py` without running a real
trial. They are **not** benchmark results and must never be published as one.

Layout mirrors a real `runs/<trial-id>/` directory just enough for
`aggregate.py`:

```
go-trial-1/
  manifest.json               framework_image, saturation window, config.app_cores
  saturation/k6-summary.json  per-workload histograms + root_group.checks
rust-trial-1/
  ...
```

The values are fabricated (two frameworks, two read workloads, a 90 s
saturation window). They exist only to prove the pipeline produces valid JSON
aggregation and a valid HTML report. `report.py` is called with a
`--notice` that labels the output as a synthetic CI fixture.

[ci]: ../../.github/workflows/ci.yml
