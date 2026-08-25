# Observability

Three sources of truth, kept in distinct services:

| Source | What it measures | Why it cannot be the only one |
| --- | --- | --- |
| k6 client | end-to-end RPS and latency percentiles, including client-side queueing | does not see server-side costs (DB time, GC, framework overhead) |
| Framework `/metrics` | per-endpoint server-side timing, in-process resource use, connection pool occupancy | depends on the framework implementing histograms honestly |
| cAdvisor + node_exporter | container and host CPU, memory, pressure-stall, steal time, network | a green dashboard here while the framework is red tells you nothing useful -- you need at least two views to triangulate a result |

A publishable run must have all three sources captured for the trial's full
duration. If any source is missing the run is recorded but flagged "incomplete"
in the manifest.

## What is on the bench_telemetry network

`prometheus` and the exporters (`node-exporter`, `cadvisor`,
`postgres-exporter`) live on `bench_telemetry` only. The measured paths
(`bench_edge` and `bench_data`) do not carry scrape traffic, so a stalled
scrape loop cannot affect the measured latency.

The cost of telemetry is still real. To bound it:

- The exporters are pinned to `cpuset: 0-1`, away from the app, db, and
  loadgen cores. A pinned exporter's CPU usage does not appear in the app's
  cgroup accounting.
- The prometheus and grafana containers are co-located with the database and
  do not have a `cpuset`. Their total scrape cost is recorded per-trial so a
  reader can see whether the database had measurable headroom throughout.

## Pressure-stall information (PSI)

`node_exporter` exposes Linux PSI metrics when run with `--collector.pressure`
(see `docker-compose.yml`). PSI is the cleanest signal that a host is
saturated: it reports the share of time *at least one* task was waiting on
CPU, memory, or I/O. A 1% sustained `cpu.pressure.some` is a strong hint that
the benchmark is no longer measuring the framework but the host's
scheduling.

## Headroom cross-check

`bench/scripts/check-db-headroom.sh` reads the database's CPU utilization
from the run's metrics and fails the trial if it ever exceeds 80%. A database
that is 90% busy cannot meaningfully tell us that a framework achieved 9,000
RPS; the bottleneck moved.

## Live access

Grafana is bound to loopback only. To view dashboards during a trial:

```bash
ssh -L 3000:127.0.0.1:3000 bench-db
# then open http://localhost:3000
```

Prometheus is bound to loopback the same way for the same reason. The
provisioning files in `infra/observability/grafana/provisioning` are not
authenticated; the network boundary is the only protection.
