---
name: Bug report
about: Report a bug in the benchmark harness, a reference implementation, or the analysis pipeline
title: ''
labels: ''
assignees: ''
---

## What went wrong

A clear, concise description of the bug.

## How to reproduce

Steps to reproduce the behavior. Include the exact commands:

```
# e.g.
./bench/scripts/up.sh
./bench/scripts/run-trial.sh go --keep
python3 bench/conformance/run.py --url http://127.0.0.1:8080 --verbose
```

## What you expected

A description of what you expected to happen.

## What actually happened

Logs, error messages, or the incorrect output.

## Environment

- OS / kernel: 
- Docker / Compose version (`docker version`, `docker compose version`):
- Framework(s) affected:

## Additional context

Anything else that helps — a run manifest, a `pg_stat_statements.csv`
excerpt, a preflight report.
