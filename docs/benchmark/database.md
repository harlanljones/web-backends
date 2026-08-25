# Database

`infra/postgres/postgresql.conf` is sized for the testbed's 8-core, 16 GB
database node. Every value that departs from the upstream default is commented
in the file itself; the *why* for the major settings lives here.

## What the benchmark measures vs. what the database does

| Component | The benchmark's interest | The database's job |
| --- | --- | --- |
| Connection pool | uniformity across frameworks | never be the cause of refusal or wait |
| WAL | uniform durability | durable at `synchronous_commit = on` |
| Autovacuum | avoid checkpoint storms inside a trial | keep up steadily |
| Planner | honest per-trial cost estimates | see the same data every trial |
| Statistics | reproducible plans | reset between trials |

The settings are chosen so that *none* of these factors varies between
candidates or between trials. A framework that turns out to be slow because
its ORM emits `SELECT *` with no LIMIT will look slow in every trial of every
candidate run; that is the kind of thing we want to surface.

## Why the seed is so large

The read workload's response set is a 400-byte `products` row. The benchmark
hits a single row by primary key, so the seed size is not a throughput
lever -- but it is a realism lever:

- 100k products is the kind of catalog size where an ORM's plan-cache, ORM
  reflection, and serialization cost together dominate the framework's
  per-request cost. On a 100-row catalog, the framework's overhead is in the
  noise and the database is the bottleneck.
- 250k orders is large enough that the dashboard's aggregate query has to
  read from disk at some point during a trial. With too few orders, the
  dashboard would be cached forever and the trial would be measuring the
  database's page cache, not the framework.

The seed is sized to make a saturated trial saturate *something* other than
the database; that is the only way to attribute throughput to the framework.

## `pg_stat_statements`

Loaded via `shared_preload_libraries` and reset at the start of every trial.
The trial's `pg_stat_statements` snapshot is part of the run manifest, and
its headline number is: how many distinct queries did this framework emit
under the four-workload mix? A framework whose ORM emits fifteen queries per
`/orders` request is doing something the contract did not ask for, and that
shows up here.

## A note on `synchronous_commit`

Set to `on`. Some benchmarks turn this off to make Postgres look faster. We
do not: the benchmark's purpose is to compare frameworks, and durability is
part of what the application pays for in production. Turning it off would
make every candidate look faster while measuring nothing about the framework.

## Reset between trials

The trial driver (see `bench/scripts/run-trial.sh`) calls
`pg_stat_statements_reset()` at the start of every trial. The seed data is
not reloaded: truncating it would mean a 90-second pause between trials, and
the seed is the same across all candidates, so a comparison is valid
whether the database is "fresh" or has one trial's worth of orders added.

If a candidate *mutates* the seed significantly (a bug or an over-eager
anonymizer, say), the trial driver re-seeds before the next candidate.
