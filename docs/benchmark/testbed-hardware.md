# Testbed hardware specification

Numbers published from this benchmark are only comparable when the testbed
matches this specification. `bench/scripts/preflight.sh` records what was
actually present so that any deviation is visible in the run manifest.

## Required specification

| Component | Requirement |
| --- | --- |
| Nodes | 3 dedicated bare-metal hosts (no virtualization, no shared tenancy) |
| CPU | identical model across all three nodes; ≥ 8 physical cores |
| Memory | ≥ 32 GB per node |
| Storage | NVMe SSD on the database node; ≥ 500 MB/s sustained write |
| Network | 10 Gbps, private switch, no other traffic on the fabric |
| OS | identical kernel version and distribution across nodes |
| Clock | NTP-synchronized, drift < 1 ms between nodes |

## Why bare metal

Virtualized and cloud instances introduce two effects that invalidate tail
latency comparisons:

- **Steal time.** A noisy neighbor appears in p99.9 as multi-millisecond spikes
  that have nothing to do with the framework under test. This is precisely the
  metric the benchmark exists to measure.
- **Burst credit accounting.** Shared-core instance types throttle after
  sustained load, so a ten-minute saturation run measures the credit balance
  rather than the framework.

If bare metal is unavailable, the fallback is dedicated-tenancy instances with
guaranteed cores, and `steal` must be recorded from `/proc/stat` throughout each
run. Any trial with non-zero steal time is discarded. This fallback is a
documented degradation, not an equivalent: see the open question in the Linear
project about the target environment.

## Node roles and sizing rationale

The load generator must be able to saturate the application node without itself
becoming the bottleneck. At 10,000 RPS with a 2 KB response the edge link
carries roughly 160 Mbps of payload — far below the fabric limit — so the
generator's constraint is CPU for TLS-free HTTP parsing and timing
bookkeeping, not bandwidth. An 8-core generator is sufficient; the preflight
script fails the run if the generator's own CPU utilization exceeds 70% during
a trial, since above that its timing measurements degrade.

## Recording actual hardware

```bash
bench/scripts/preflight.sh --json > runs/<run-id>/hardware-<role>.json
```

The run manifest embeds one of these per node. `bench/scripts/verify-manifest.sh`
checks the three files for CPU-model equality and kernel-version equality and
refuses to mark a run publishable when they differ.
