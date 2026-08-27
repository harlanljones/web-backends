# Security Policy

This repository is an engineering reference: a set of benchmark harnesses,
reference implementations, and analysis scripts. It is not a deployed service
and does not process user data.

## Reporting a vulnerability

If you believe you have found a security issue, please report it privately.
Open a [security advisory](https://github.com/harlanljones/web-backends/security/advisories/new)
on the repository, or contact the maintainer directly. Do not open a public
issue for a suspected vulnerability.

We will respond as promptly as we can, confirm the issue, and credit the
reporter in the release notes unless you ask to remain anonymous.

## Scope

The following are in scope:

- A reference implementation under `apps/` that mishandles input, leaks a
  connection, or opens the database to SQL injection beyond the contract.
- The orchestration scripts (`bench/scripts/`) or `docker-compose.yml` exposing
  a credential or a privileged surface.
- The analysis pipeline (`bench/analysis/`) reading untrusted input in an
  unsafe way.

The following are **not** in scope (they are deliberate design choices):

- The observability stack (Grafana, Prometheus) is bound to loopback and
  **intentionally unauthenticated** — see
  [`docs/benchmark/observability.md`](docs/benchmark/observability.md). The
  network boundary is the protection; exposing those ports is unsupported.
- The load generator runs as `user: "0:0"` inside its container. This is a
  closed testbed with no hostile code surface, documented in
  `docker-compose.yml`.
- Default credentials in `.env.example` (`change-me-before-running`). These are
  placeholders; `.env` is gitignored and the compose file refuses to start
  without `POSTGRES_PASSWORD` and `GRAFANA_ADMIN_PASSWORD` being set.

## Responsible disclosure expectations

This is a single-maintainer project. There is no service-level agreement for a
fix. Security fixes are released in the next tagged release; report findings
with enough detail to reproduce and we will prioritize them by severity.
