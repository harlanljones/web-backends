# Benchmark design

These pages specify how a measurement run works, from the HTTP contract up to
the published artifact. Read them in roughly this order:

1. **[app-contract.md](app-contract.md)** — the six endpoints and three
   environment variables every framework implements. The whole comparison
   hangs off this one contract.
2. **[testbed.md](testbed.md)** — the three-node topology (loadgen, app, db),
   the network separation, and the `single` vs `distributed` modes.
3. **[testbed-hardware.md](testbed-hardware.md)** — the hardware a *publishable*
   result requires (bare metal, identical nodes, NTP). Anything else is a
   development run, not a measurement.
4. **[resources.md](resources.md)** — the cpuset/memory/log boundaries that make
   the comparison "at equal cost".
5. **[database.md](database.md)** — PostgreSQL tuning and the seed rationale.
6. **[observability.md](observability.md)** — k6 + framework `/metrics` +
   cAdvisor/node-exporter, and why one source is never enough.
7. **[environment.md](environment.md)** — pinned toolchains, image tags, and
   lockfiles. Version-sensitivity is a feature, not an accident.
8. **[run-manifest.md](run-manifest.md)** — the complete per-trial artifact
   layout, so any published number can be audited down to the raw files.
9. **[execution-plan.md](execution-plan.md)** — how the work was decomposed into
   milestones and what "done" means for each.

## The one rule that matters

A number is only a *benchmark result* if it came from a conforming testbed
(bare metal, preflight clean, five trials with burn-in discarded). Everything
else — including the single-host development runs — is explicitly labeled and
never blended into a measurement. See `docs/results/README.md`.
