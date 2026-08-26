# Environment and dependency versions

The benchmark is version-sensitive. This page lists what each piece
needs and where the exact versions are pinned. Read it before running a
trial — a version mismatch is a common cause of a non-reproducible
result.

## Host prerequisites

The testbed (see `testbed-hardware.md`) is three identical bare-metal
hosts. For development/smoke you only need a single Linux host with:

- **Docker** with **Compose v2** (`docker compose`). Verified against
  Docker 29 / Compose 5.
- **python3** (3.12+) for the seed generator, conformance harness, and
  analyzers.
- **curl** for the health checks and the trial driver.

Each reference also needs its runtime *only if you build it outside
Docker*:

| Tool | Version | Used by |
| --- | --- | --- |
| go | 1.26 | `apps/go` |
| cargo / rustc | 1.97 | `apps/rust` |
| node | 26 | `apps/node` |
| bun | 1.4 | `apps/bun` |
| python / uv | 3.12 / 0.12 | `apps/python` |
| maven + JDK | 3.9 / 21 | `apps/spring` |
| dotnet | 8.0 | `apps/aspnet` |
| elixir / mix | 1.16 / OTP 26 | `apps/phoenix` |

None of these are required to run the testbed — every framework builds
inside Docker.

## Pinned image versions

The testbed pins exact image tags (not `latest`) so a trial is the same
today and in six months. See `docker-compose.yml`:

| Service | Image tag |
| --- | --- |
| database | `postgres:${POSTGRES_VERSION:-16}` |
| seeder | `python:3.12-slim` |
| load generator | `grafana/k6:0.50.0` |
| prometheus | `prom/prometheus:v2.53.0` |
| grafana | `grafana/grafana:11.1.0` |
| node-exporter | `prom/node-exporter:v1.8.1` |
| cadvisor | `gcr.io/cadvisor/cadvisor:v0.49.1` |
| postgres-exporter | `quay.io/prometheuscommunity/postgres-exporter:v0.15.0` |

`POSTGRES_VERSION` is configurable in `.env`; the rest are baked into the
compose file deliberately so a stray `docker pull` cannot change a run.

## Dependency locks

Every reference commits its lockfile so the dependency graph is
reproducible:

- `apps/go/go.sum` (Go modules)
- `apps/rust/Cargo.lock`
- `apps/node/package-lock.json`
- `apps/bun/bun.lock`
- `apps/python/uv.lock`
- `apps/spring/pom.xml` (Maven resolves to the same graph given a
  locked `pom.xml`)
- `apps/phoenix/mix.lock`

## Environment variables

`.env.example` documents every variable with its default. The three the
contract requires of every framework are `DATABASE_URL`, `DB_POOL_SIZE`,
and `LOG_LEVEL`; `.env` adds the testbed-level settings (networks,
resource boundaries, observability ports, seed sizes). Never commit
`.env`.

## Known version constraints

- The Rust reference uses `panic = "abort"` + LTO in `[profile.release]`;
  it builds with Rust 1.97.
- The Spring reference targets Spring Boot 3.4 with virtual threads
  (`spring.threads.virtual.enabled=true`) on a JDK 21 runtime.
- The Phoenix reference is an escript built on Elixir 1.16 / OTP 26. It
  uses Bandit (a Plug server) directly; the dependency tree is pinned by
  `mix.lock`.
