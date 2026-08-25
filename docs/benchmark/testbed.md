# Benchmark testbed

The experimental design calls for three isolated nodes on a private 10 Gbps
network:

| Role | Hostname | Purpose |
| --- | --- | --- |
| `loadgen` | `bench-load` | k6 / wrk2 load generation only |
| `app` | `bench-app` | the framework under test, one at a time |
| `db` | `bench-db` | PostgreSQL 16 + telemetry stack |

The topology is expressed as Docker Compose profiles so the same definitions run
in two modes.

## Modes

### `single` (development / smoke)

Everything runs on one host. Networks are still separated so that service
discovery names and per-network isolation match the distributed layout, but
results from this mode are **not** publishable: the load generator competes with
the application for CPU.

```bash
just up            # or: bench/scripts/up.sh single
```

### `distributed` (measurement)

One Compose invocation per host, targeted through `DOCKER_HOST`, each bringing up
only its own profile. Cross-host addressing goes through the private-network IPs
in `.env`, never through container DNS.

```bash
# on the operator workstation
export $(grep -v '^#' .env | xargs)
DOCKER_HOST=ssh://bench-db   docker compose --profile db        up -d
DOCKER_HOST=ssh://bench-db   docker compose --profile telemetry up -d
DOCKER_HOST=ssh://bench-app  docker compose --profile app       up -d
DOCKER_HOST=ssh://bench-load docker compose --profile loadgen   up -d
```

Only `db` and `telemetry` share a host. That co-location is deliberate: the
telemetry stack must not steal cycles from the application under test, and the
database node has headroom at the RPS levels being measured. Its scrape cost is
recorded in every run manifest so it can be audited (see
`docs/benchmark/observability.md`).

## Networks

| Network | Members | Notes |
| --- | --- | --- |
| `bench_edge` | loadgen → app | carries only benchmark request traffic |
| `bench_data` | app → db | carries only SQL |
| `bench_telemetry` | prometheus → all exporters | scrape traffic, isolated from the measured paths |

Separating edge from data traffic means a saturated request path cannot delay
the database connection, and the telemetry scrape never shares a bridge with
either. In `distributed` mode each network maps to a distinct VLAN on the
private switch; in `single` mode they are three local bridges.

MTU is pinned to 9000 on `bench_edge` and `bench_data` to match jumbo frames on
the 10 Gbps fabric. If the physical fabric does not support jumbo frames, set
`BENCH_MTU=1500` — a mismatch silently costs throughput through fragmentation.

## Host prerequisites

Run `bench/scripts/preflight.sh` on each node. It verifies and reports, without
changing anything:

- CPU governor is `performance` (not `powersave`/`schedutil`)
- Simultaneous multithreading state is recorded (either setting is fine; it must
  be *identical* across trials)
- `net.core.somaxconn` ≥ 65535, `net.ipv4.tcp_max_syn_backlog` ≥ 65535
- ephemeral port range is widened (`net.ipv4.ip_local_port_range = 1024 65535`)
- `nf_conntrack` is either absent or its table is ≥ 1M entries
- transparent huge pages state is recorded
- no swap in use on the app node
- NIC ring buffers at hardware maximum, offloads recorded
- clock is NTP-synchronized across all three nodes (latency percentiles are
  compared across hosts)

Preflight failures block a measurement run. `bench/scripts/preflight.sh --fix`
applies the sysctl and governor changes that are safe to automate; it never
touches NIC firmware settings or SMT.

## Ephemeral port exhaustion

At 10,000 RPS with short-lived connections a single load generator will exhaust
its ephemeral ports in under a minute. The k6 configuration therefore uses
keep-alive connection pools with a fixed VU count rather than
connection-per-request. This is a deliberate deviation from "worst case" HTTP
behavior and is recorded in the report: the benchmark measures request
throughput on warm connections, not TCP handshake throughput.

## What this repository does not provision

Physical machine acquisition, switch VLAN configuration, and OS installation are
out of scope for code. `docs/benchmark/testbed-hardware.md` records the exact
specification that must be matched, and the run manifest captures what was
actually observed so a reader can tell whether a published number came from a
conforming testbed.
