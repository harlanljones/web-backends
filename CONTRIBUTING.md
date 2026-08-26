# Contributing

Thank you for contributing to the Modern Web Framework Performance &
Scalability Benchmark. This is an engineering reference, not a library:
the goal is reproducible, legible, and honest benchmark code.

## Ground rules

Everything lives in this repository. We do not ask you to run the
testbed or produce results; we ask you to write code and documentation
that a stranger can build and reason about without hidden magic.

- **One framework per directory.** New references go in `apps/<framework>/`
  with a Dockerfile producing `bench/<framework>:latest`, a README, and
  an entry in `bench/frameworks.yaml`.
- **The contract is the bar.** Every reference implements the four
  workloads + `/health` + `/metrics` per `contracts/openapi.yaml` and
  must pass `bench/conformance/run.py` (9/9). A framework that does not
  pass is an example, not a result.
- **No secret sauce.** The benchmark measures the framework, not your
  ORM. No caching that would make a framework look faster than it is,
  no second connection pool on top of `DB_POOL_SIZE`, no per-request
  logging at `LOG_LEVEL=warn`.
- **Type fidelity.** Map SQL column types faithfully (bigint vs
  integer). A mismatch is a hard error, not a silent cast.

## Setup

Prerequisites: Docker with Compose v2, `python3`, and `curl`. The
toolchains per language are only needed to run a reference outside
Docker; every reference builds inside Docker.

```bash
cp .env.example .env
$EDITOR .env         # set POSTGRES_PASSWORD and GRAFANA_ADMIN_PASSWORD
./bench/scripts/up.sh
```

The exact toolchain versions each framework pins are listed in its
`apps/<framework>/Dockerfile` (and `mix.lock`/`Cargo.lock`/`package-lock.json`
where applicable). The benchmark is version-sensitive; keep lockfiles
committed.

## Running a local check

Bring the testbed up, then run a single reference and the conformance
suite against it:

```bash
./bench/scripts/run-trial.sh go --keep
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

`run-trial.sh` builds the image, starts the app against the seeded
database, and waits for `/health`. The conformance runner asserts the
contract. To run a full measurement trial:

```bash
./bench/scripts/exec-trial.sh <trial-id>
```

## Running the tests / linters

There is no single test command; the pieces are:

- `python3 bench/conformance/run.py --url <app>` — the contract harness.
- `python3 bench/analysis/aggregate.py --runs runs --json` — aggregation.
- `bash -n bench/scripts/*.sh` — shell syntax.
- Per-language check: `cargo build --release` (rust), `mvn -DskipTests
  package` (spring), `dotnet build` (aspnet) — all run inside the
  Dockerfile build.

## Ticket workflow

Work is tracked in [Linear][linear]. Before starting, read
`docs/agents/issue-tracker.md`. Pick the lowest-numbered open,
unassigned, unblocked ticket; claim it (`--assignee self`); and record
your resolution as a comment before closing it.

[linear]: https://linear.app/harlanljones/project/modern-web-framework-performance-and-scalability-benchmark-ab0154b66a94

## Commit style

Keep commits small and focused. The repo already has a `docs:`-prefixed
commit for the early infrastructure; match that tone. Never commit
secrets, `.env`, build artifacts, or `runs/` output.

## What we will not accept without a strong reason

- Benchmarks that mutate the seed data across runs.
- Metric names that differ from `http_request_duration_seconds_*` (the
  Prometheus recording rule and Grafana dashboard depend on it).
- A reference that logs per request at `LOG_LEVEL=warn`.
