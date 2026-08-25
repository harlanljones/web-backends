# Issue tracker

This repository tracks work in **Linear**.

| Field | Value |
| --- | --- |
| Workspace | `harlanljones` |
| Team | `HJ` (Harlan Jones) |
| Project | Modern Web Framework Performance & Scalability Benchmark (`ab0154b66a94`) |
| CLI | `linear` (`@schpet/linear-cli` 2.5.0), resolved at `~/.cache/.bun/bin/linear` |
| Credentials | `LINEAR_API_KEY` from `~/.linear.toml` (chezmoi-managed, never printed) |

## Conventions

- `issue query` requires a team scope in this workspace: always pass `--team HJ`
  (there is no default team configured). Add `--project ab0154b66a94` to scope to
  this project.
- The completed workflow state for team HJ is type `completed`; the open state is
  `Todo` (type `unstarted`).
- No labels are in use on this project. Frontier selection is by **parent +
  state + assignee + blocking relations**, not by label.
- Relations: this project's tickets carry no `blocks`/`blocked-by` edges. The
  dependency order is implied by the milestone tree
  (HJ-356 → HJ-357 → HJ-358 → HJ-359) and is documented in
  `docs/benchmark/execution-plan.md`.

## Ticket tree

```
HJ-356 Set up benchmark infrastructure
  HJ-360 Provision isolated three-node testbed
  HJ-361 Configure PostgreSQL benchmark database
  HJ-362 Set container resource boundaries
  HJ-363 Add benchmark observability
HJ-357 Build framework reference implementations
  HJ-364 Define shared API contracts and data model
  HJ-365 Implement serialization and read workloads
  HJ-366 Implement transactional write workload
  HJ-367 Implement compute and rendering workload
HJ-358 Run benchmark experiments
  HJ-368 Define reproducible load-test scripts
  HJ-369 Execute warm-up and ramp tests
  HJ-370 Run saturation trials and collect telemetry
HJ-359 Analyze results and publish reference
  HJ-371 Aggregate benchmark results
  HJ-372 Compare framework trade-offs
  HJ-373 Publish decision guide and reference materials
```

## Loading credentials

```bash
export LINEAR_API_KEY="$(sed -n 's/^LINEAR_API_KEY[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' "$HOME/.linear.toml")"
```
