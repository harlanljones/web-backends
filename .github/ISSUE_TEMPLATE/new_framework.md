---
name: New framework proposal
about: Propose a new framework (or a different stack for an existing framework) to add to the benchmark
title: 'Add framework: <name>'
labels: ''
assignees: ''
---

## Framework

- Name (and language / runtime):
- Directory it would live in (`apps/<framework>/`):
- Router / server:
- Database driver (no ORM, per `CONTRIBUTING.md`):

## Why this belongs in the benchmark

A short justification: what language family, runtime model, or concurrency
approach does it add that the current eight do not cover?

## Contract commitment

By proposing this, you agree the reference will:

- implement the four workload endpoints + `/health` + `/metrics` per
  `contracts/openapi.yaml`;
- read exactly `DATABASE_URL`, `DB_POOL_SIZE`, and `LOG_LEVEL`;
- pass `bench/conformance/run.py` (9/9);
- commit its lockfile and ship a `bench/<framework>:latest` Docker image.

## Checklist for the implementation

- [ ] `apps/<framework>/Dockerfile` builds `bench/<framework>:latest`
- [ ] `apps/<framework>/README.md` documents non-obvious choices
- [ ] Registered in `bench/frameworks.yaml`
- [ ] Conformance 9/9 against a live Postgres
