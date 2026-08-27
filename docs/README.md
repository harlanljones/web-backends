# Documentation

The documentation is organized by audience and concern.

## Benchmark design and methodology

Everything a reader needs to trust — or reproduce — the benchmark lives under
[`benchmark/`](benchmark/):

| Page | Covers |
| --- | --- |
| [`app-contract.md`](benchmark/app-contract.md) | The HTTP contract every framework implements |
| [`execution-plan.md`](benchmark/execution-plan.md) | Milestone/ticket decomposition and definition of done |
| [`testbed.md`](benchmark/testbed.md) | The three-node topology and the two run modes |
| [`testbed-hardware.md`](benchmark/testbed-hardware.md) | The exact hardware a publishable run requires |
| [`resources.md`](benchmark/resources.md) | CPU/memory/log boundaries and why they exist |
| [`database.md`](benchmark/database.md) | PostgreSQL tuning, seed sizing, and `pg_stat_statements` |
| [`observability.md`](benchmark/observability.md) | The three telemetry sources and how to triangulate a result |
| [`environment.md`](benchmark/environment.md) | Pinned toolchains, images, and lockfiles |
| [`run-manifest.md`](benchmark/run-manifest.md) | The full per-trial artifact layout and its fields |

## For AI agents

[`agents/issue-tracker.md`](agents/issue-tracker.md) documents the Linear
project, ticket conventions, and credential handling for automated workflows.

## Results

[`results/`](results/) holds published benchmark reports. Read its
[README](results/README.md) before treating any number there as a measurement:
the repository distinguishes the bare-metal publishable result from
single-host development runs, and never publishes fabricated numbers.
