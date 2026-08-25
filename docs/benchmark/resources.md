# Container resource boundaries

Every service in `docker-compose.yml` has a `cpuset`, `cpus`, and `mem_limit`
applied. The boundaries are not negotiable: a measurement run that does not
respect them is not publishable, because the whole point of the benchmark is to
compare frameworks at equal cost.

## Cores

Each role has a fixed `cpuset` drawn from the host's physical cores:

| Role | Default cpuset | Notes |
| --- | --- | --- |
| app | `2-5` (4 cores) | the framework under test |
| db  | `8-15` (8 cores) | sized so the database is never the bottleneck |
| loadgen | `2-9` (8 cores) | sized so the generator is not the bottleneck |
| node-exporter, cadvisor, postgres-exporter, seeder | `0-1` (2 cores) | telemetry housekeeping, isolated from the measured paths |
| prometheus, grafana | (no cpuset) | co-located with db; their scrape cost is recorded in the run manifest |

Two things this deliberately does NOT do:

- It does not hand the database fewer cores than the app. Under-controlling the
  database invites a database-bound trial that gets attributed to the
  framework. The cross-check lives in `bench/scripts/check-db-headroom.sh`.
- It does not rely on CFS quotas alone. `cpuset` pinning is the only thing that
  keeps the app from being scheduled onto a core where the load generator is
  also busy; on a single-host "development" mode this is a coincidence, but on
  the distributed testbed it is essential.

### Setting `cpuset` to a contiguous NUMA node

The pinned cores should be on the same NUMA node as the memory they are
touching. On a typical 2-socket system, pins `0-5` are NUMA 0 and pins `6-11`
are NUMA 1. A framework whose memory allocations cross sockets will pay
additional latency, and that cost will be measured as framework overhead.

`bench/scripts/preflight.sh` records the NUMA topology of the host it runs on.
The run manifest embeds it so a reader can see whether the pinning was honest.

## Memory

`mem_limit` is matched by `memswap_limit`. The app container will be OOM-killed
before it swaps, on purpose: swapped pages would make RSS comparisons across
frameworks invalid, and a small over-limit container is better than a noisy
result.

The database is given 16 GB; PostgreSQL's `shared_buffers` is sized to 4 GB
(see `infra/postgres/postgresql.conf`). The remainder is for connection state
and for the OS page cache covering the seed data set.

## Logging

Logging is a measured cost. Every container is pinned to `json-file` with a
hard cap of `max-size: 16m` × `max-file: 3` (about 48 MB per service). The
framework itself is configured to emit WARN and above (see
`docs/benchmark/app-contract.md`), so log volume is comparable across
candidates. A noisy framework that produces a gigabyte of debug logs would, on
a 10 Gbps link, not measurably slow the path -- but on a 1 Gbps link or under
journald it would, and that effect would not be uniform across candidates.

## What the framework must respect

Every framework's Dockerfile is required to honor three settings the operator
overrides through environment variables:

1. `LOG_LEVEL` -- frameworks may interpret it as they choose, but the recorded
   volume at the chosen level must be at most ~1 KB/s per 1000 RPS.
2. `DB_POOL_SIZE` -- the framework must open exactly that many connections to
   the database, no more. A framework that opens its own pool on top of the
   configured one would silently bypass the limit and double the database's
   connection count.
3. `PORT` -- the framework must listen on the port given. Health checks and
   scrape targets assume `8080`.

These are the same three variables for every candidate, and they are the
minimum cross-language common surface for the contract.
